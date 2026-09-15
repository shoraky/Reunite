-- Add city coordinates and location-based notifications without resetting data.
ALTER TABLE city ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION;
ALTER TABLE city ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;
DO $$ BEGIN
  ALTER TABLE city ADD CONSTRAINT city_coordinates_valid CHECK (
    (latitude IS NULL AND longitude IS NULL) OR
    (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- The deployed database had an older notification shape. Preserve its rows while
-- converging on the current model; legacy presentation columns remain nullable
-- for backwards compatibility but are not used by the API.
DO $$ BEGIN
  IF to_regclass('public.notification') IS NULL THEN
    CREATE TABLE notification (
      id BIGSERIAL PRIMARY KEY,
      user_id BIGINT NOT NULL REFERENCES "User"(user_id) ON DELETE CASCADE,
      report_id BIGINT NOT NULL REFERENCES report(report_id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      is_read BOOLEAN NOT NULL DEFAULT false,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  ELSE
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='notification_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='id') THEN
      ALTER TABLE notification RENAME COLUMN notification_id TO id;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='case_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='report_id') THEN
      ALTER TABLE notification RENAME COLUMN case_id TO report_id;
    END IF;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS id BIGSERIAL;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS user_id BIGINT;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS report_id BIGINT;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS type TEXT;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT false;
    ALTER TABLE notification ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='title') THEN
      ALTER TABLE notification ALTER COLUMN title DROP NOT NULL;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='body') THEN
      ALTER TABLE notification ALTER COLUMN body DROP NOT NULL;
    END IF;
    ALTER TABLE notification ALTER COLUMN type SET NOT NULL;
    ALTER TABLE notification ALTER COLUMN is_read SET DEFAULT false;
    UPDATE notification SET is_read = false WHERE is_read IS NULL;
    ALTER TABLE notification ALTER COLUMN is_read SET NOT NULL;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notification' AND column_name='metadata') THEN
    EXECUTE $sql$
      UPDATE notification
      SET report_id = COALESCE(report_id, NULLIF(metadata->>'caseId', '')::BIGINT)
      WHERE report_id IS NULL
        AND EXISTS (SELECT 1 FROM report r WHERE r.report_id = NULLIF(metadata->>'caseId', '')::BIGINT)
    $sql$;
  END IF;
END $$;

DO $$ BEGIN
  ALTER TABLE notification ADD CONSTRAINT notification_user_id_fkey FOREIGN KEY (user_id) REFERENCES "User"(user_id) ON DELETE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE notification ADD CONSTRAINT notification_report_id_fkey FOREIGN KEY (report_id) REFERENCES report(report_id) ON DELETE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS notification_user_report_uidx
  ON notification(user_id, report_id) WHERE user_id IS NOT NULL AND report_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS notification_user_created_idx ON notification(user_id, created_at DESC);

-- Coordinates are populated below by the accompanying data migration generated
-- from GeoNames and ArcGIS World Geocoding results.
