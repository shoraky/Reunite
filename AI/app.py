import os
import shutil
import tempfile
import zipfile
from pathlib import Path
from urllib.request import Request, urlopen

import cv2
import gradio as gr
import numpy as np
import spaces
import torch
import torch.nn as nn
import torch.nn.functional as F
from dotenv import load_dotenv
from huggingface_hub import hf_hub_download
from insightface.app import FaceAnalysis
from insightface.utils import face_align
from PIL import Image
from torchvision import models, transforms

load_dotenv()

# Each of the three ensemble models currently emits a 512-value vector.
# The service returns their concatenation, so its public embedding dimension is
# 1536. Keep the component dimension separate from the output dimension.
MODEL_EMBEDDING_DIM = 512
EMBEDDING_DIM = MODEL_EMBEDDING_DIM * 3
COMBINED_DIM = EMBEDDING_DIM
MODEL_PATH = Path(os.getenv("MODEL_PATH", "/tmp/encoder.pth"))
MODEL_URL = os.getenv("MODEL_URL", "https://www.kaggle.com/api/v1/datasets/download/mhmdelshoraky/best-encoder-model?datasetVersionNumber=1")

WEIGHT_BUFFALO = float(os.getenv("WEIGHT_BUFFALO", "0.4"))
WEIGHT_ANTELOPE = float(os.getenv("WEIGHT_ANTELOPE", "0.35"))
WEIGHT_AGEDB = float(os.getenv("WEIGHT_AGEDB", "0.25"))

ANTELOPEV2_REPO = "DIAMONIK7777/antelopev2"
ANTELOPEV2_FILES = ["1k3d68.onnx", "2d106det.onnx", "genderage.onnx", "glintr100.onnx", "scrfd_10g_bnkps.onnx"]
ANTELOPEV2_DIR = Path.home() / ".insightface" / "models" / "antelopev2"


class Siamese(nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = models.resnet50(weights=None)
        self.backbone.fc = nn.Identity()
        self.head = nn.Sequential(nn.Linear(2048, 1024), nn.ReLU(), nn.Linear(1024, MODEL_EMBEDDING_DIM))

    def forward(self, image):
        return F.normalize(self.head(self.backbone(image)), p=2, dim=1)


def download_agedb_model():
    if MODEL_PATH.is_file():
        return
    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp_dir:
        archive = Path(temp_dir) / "model.zip"
        request = Request(MODEL_URL, headers={"User-Agent": "Reunite AI"})
        with urlopen(request, timeout=300) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        with zipfile.ZipFile(archive) as zipped:
            candidates = [e for e in zipped.infolist() if not e.is_dir() and Path(e.filename).suffix.lower() in {".pt", ".pth", ".ckpt"}]
            if not candidates:
                raise RuntimeError("Model checkpoint was not found.")
            with zipped.open(candidates[0]) as source, MODEL_PATH.open("wb") as output:
                shutil.copyfileobj(source, output)


def load_agedb_model():
    download_agedb_model()
    checkpoint = torch.load(MODEL_PATH, map_location="cpu")
    if isinstance(checkpoint, dict):
        checkpoint = checkpoint.get("state_dict", checkpoint.get("model_state_dict", checkpoint))
    model = Siamese()
    model.load_state_dict(checkpoint)
    model.eval()
    return model


def ensure_antelopev2():
    ANTELOPEV2_DIR.mkdir(parents=True, exist_ok=True)
    if all((ANTELOPEV2_DIR / name).is_file() for name in ANTELOPEV2_FILES):
        return
    for name in ANTELOPEV2_FILES:
        target = ANTELOPEV2_DIR / name
        if target.is_file():
            continue
        downloaded = hf_hub_download(repo_id=ANTELOPEV2_REPO, filename=name)
        shutil.copy(downloaded, target)


agedb_model = load_agedb_model()
agedb_preprocess = transforms.Compose([transforms.Resize((224, 224)), transforms.ToTensor()])

buffalo_app = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])
buffalo_app.prepare(ctx_id=-1, det_size=(640, 640))

ensure_antelopev2()
antelope_app = FaceAnalysis(name="antelopev2", providers=["CPUExecutionProvider"])
antelope_app.prepare(ctx_id=-1, det_size=(640, 640))


def get_primary_face(app, bgr_image):
    faces = app.get(bgr_image)
    if not faces:
        return None
    return max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))


def weighted_concat(vectors_and_weights):
    total_sq = sum(w * w for _, w in vectors_and_weights)
    scale = 1.0 / np.sqrt(total_sq) if total_sq > 0 else 1.0
    parts = []
    for vec, w in vectors_and_weights:
        vec = np.asarray(vec, dtype=np.float32)
        norm = np.linalg.norm(vec) + 1e-12
        parts.append((w * scale) * (vec / norm))
    return np.concatenate(parts).astype(np.float32)


@spaces.GPU
def embed(image):
    if image is None:
        raise gr.Error("Image data is required.")
    if not isinstance(image, Image.Image):
        image = Image.fromarray(np.asarray(image))
    image = image.convert("RGB")

    rgb = np.array(image)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    buffalo_face = get_primary_face(buffalo_app, bgr)
    if buffalo_face is None:
        raise gr.Error("No face detected in the photo.")
    buffalo_embedding = buffalo_face.normed_embedding

    antelope_face = get_primary_face(antelope_app, bgr)
    if antelope_face is None:
        raise gr.Error("No face detected in the photo.")
    antelope_embedding = antelope_face.normed_embedding

    aligned_bgr = face_align.norm_crop(bgr, landmark=buffalo_face.kps, image_size=224)
    aligned_rgb = cv2.cvtColor(aligned_bgr, cv2.COLOR_BGR2RGB)
    aligned_pil = Image.fromarray(aligned_rgb)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    agedb_model.to(device)
    tensor = agedb_preprocess(aligned_pil).unsqueeze(0).to(device)
    with torch.inference_mode():
        agedb_embedding = agedb_model(tensor).squeeze(0).cpu().numpy().astype(np.float32)

    combined = weighted_concat([
        (buffalo_embedding, WEIGHT_BUFFALO),
        (antelope_embedding, WEIGHT_ANTELOPE),
        (agedb_embedding, WEIGHT_AGEDB),
    ])

    if combined.size != EMBEDDING_DIM or not np.isfinite(combined).all():
        raise gr.Error("The model produced an invalid embedding.")

    return combined.tolist()


demo = gr.Interface(fn=embed, inputs=gr.Image(type="pil"), outputs=gr.JSON(), api_name="embed")
demo.launch()
