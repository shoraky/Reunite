-- Normalize the existing notification table to the application model.
-- Refuse to remove legacy fields if another deployment still contains data.
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='notification' AND column_name IN ('title','body','metadata')
  ) AND EXISTS (SELECT 1 FROM notification) THEN
    RAISE EXCEPTION 'notification contains rows; migrate legacy data before removing title/body/metadata';
  END IF;
END $$;

ALTER TABLE notification DROP COLUMN IF EXISTS title;
ALTER TABLE notification DROP COLUMN IF EXISTS body;
ALTER TABLE notification DROP COLUMN IF EXISTS metadata;

ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_case_id_fkey;
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_report_id_fkey;
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_user_id_fkey;
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_user_report_key;

ALTER TABLE notification ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE notification ALTER COLUMN report_id SET NOT NULL;
ALTER TABLE notification ALTER COLUMN is_read SET DEFAULT false;
ALTER TABLE notification ALTER COLUMN is_read SET NOT NULL;
ALTER TABLE notification ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE notification ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE notification
  ADD CONSTRAINT notification_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES "User"(user_id) ON DELETE CASCADE;
ALTER TABLE notification
  ADD CONSTRAINT notification_report_id_fkey
  FOREIGN KEY (report_id) REFERENCES report(report_id) ON DELETE CASCADE;
ALTER TABLE notification
  ADD CONSTRAINT notification_user_report_key UNIQUE (user_id, report_id);

DROP INDEX IF EXISTS notification_user_report_uidx;
