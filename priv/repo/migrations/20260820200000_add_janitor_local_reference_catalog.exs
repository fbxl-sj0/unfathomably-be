# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddJanitorLocalReferenceCatalog do
  use Ecto.Migration

  def up do
    create table(:janitor_local_references, primary_key: false) do
      add(:source_kind, :string, size: 1, null: false)
      add(:source_id, :text, null: false)
      add(:reference, :text, null: false)
    end

    create(
      unique_index(:janitor_local_references, [:source_kind, :source_id, :reference],
        name: :janitor_local_references_source_index
      )
    )

    create(
      index(:janitor_local_references, [:reference],
        name: :janitor_local_references_reference_index
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION refresh_janitor_local_activity_reference()
    RETURNS trigger AS $$
    DECLARE
      object_reference text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        DELETE FROM janitor_local_references
        WHERE source_kind = 'a' AND source_id = OLD.id::text;

        RETURN OLD;
      END IF;

      DELETE FROM janitor_local_references
      WHERE source_kind = 'a' AND source_id = NEW.id::text;

      IF NEW.local = true THEN
        object_reference := associated_object_id(NEW.data);

        IF object_reference IS NOT NULL AND object_reference <> '' THEN
          INSERT INTO janitor_local_references (source_kind, source_id, reference)
          VALUES ('a', NEW.id::text, object_reference)
          ON CONFLICT DO NOTHING;
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION refresh_janitor_local_object_references()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        DELETE FROM janitor_local_references
        WHERE source_kind = 'o' AND source_id = OLD.id::text;

        RETURN OLD;
      END IF;

      DELETE FROM janitor_local_references
      WHERE source_kind = 'o' AND source_id = NEW.id::text;

      IF EXISTS (
        SELECT 1
        FROM users AS local_actor
        WHERE local_actor.local = true
          AND local_actor.ap_id = NEW.data->>'actor'
      ) THEN
        INSERT INTO janitor_local_references (source_kind, source_id, reference)
        SELECT 'o', NEW.id::text, candidate_reference
        FROM unnest(ARRAY[
          NEW.data->>'inReplyTo',
          NEW.data->>'quoteUrl',
          NEW.data->>'quoteUri'
        ]) AS candidate_reference
        WHERE candidate_reference IS NOT NULL AND candidate_reference <> ''
        ON CONFLICT DO NOTHING;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER janitor_local_activity_reference_insert
    AFTER INSERT ON activities
    FOR EACH ROW
    WHEN (NEW.local = true)
    EXECUTE FUNCTION refresh_janitor_local_activity_reference()
    """)

    execute("""
    CREATE TRIGGER janitor_local_activity_reference_update
    AFTER UPDATE OF data, local ON activities
    FOR EACH ROW
    WHEN (OLD.local = true OR NEW.local = true)
    EXECUTE FUNCTION refresh_janitor_local_activity_reference()
    """)

    execute("""
    CREATE TRIGGER janitor_local_activity_reference_delete
    AFTER DELETE ON activities
    FOR EACH ROW
    WHEN (OLD.local = true)
    EXECUTE FUNCTION refresh_janitor_local_activity_reference()
    """)

    execute("""
    CREATE TRIGGER janitor_local_object_reference_insert
    AFTER INSERT ON objects
    FOR EACH ROW
    WHEN (
      NEW.data->>'inReplyTo' IS NOT NULL
      OR NEW.data->>'quoteUrl' IS NOT NULL
      OR NEW.data->>'quoteUri' IS NOT NULL
    )
    EXECUTE FUNCTION refresh_janitor_local_object_references()
    """)

    execute("""
    CREATE TRIGGER janitor_local_object_reference_update
    AFTER UPDATE OF data ON objects
    FOR EACH ROW
    WHEN (
      OLD.data->>'inReplyTo' IS NOT NULL
      OR OLD.data->>'quoteUrl' IS NOT NULL
      OR OLD.data->>'quoteUri' IS NOT NULL
      OR NEW.data->>'inReplyTo' IS NOT NULL
      OR NEW.data->>'quoteUrl' IS NOT NULL
      OR NEW.data->>'quoteUri' IS NOT NULL
    )
    EXECUTE FUNCTION refresh_janitor_local_object_references()
    """)

    execute("""
    CREATE TRIGGER janitor_local_object_reference_delete
    AFTER DELETE ON objects
    FOR EACH ROW
    WHEN (
      OLD.data->>'inReplyTo' IS NOT NULL
      OR OLD.data->>'quoteUrl' IS NOT NULL
      OR OLD.data->>'quoteUri' IS NOT NULL
    )
    EXECUTE FUNCTION refresh_janitor_local_object_references()
    """)

    execute("""
    INSERT INTO janitor_local_references (source_kind, source_id, reference)
    SELECT 'a', local_activity.id::text, associated_object_id(local_activity.data)
    FROM activities AS local_activity
    WHERE local_activity.local = true
      AND associated_object_id(local_activity.data) IS NOT NULL
      AND associated_object_id(local_activity.data) <> ''
    ON CONFLICT DO NOTHING
    """)

    execute("""
    INSERT INTO janitor_local_references (source_kind, source_id, reference)
    SELECT 'o', local_object.id::text, candidate_reference
    FROM users AS local_actor
    JOIN objects AS local_object
      ON local_object.data->>'actor' = local_actor.ap_id
    CROSS JOIN LATERAL unnest(ARRAY[
      local_object.data->>'inReplyTo',
      local_object.data->>'quoteUrl',
      local_object.data->>'quoteUri'
    ]) AS candidate_reference
    WHERE local_actor.local = true
      AND candidate_reference IS NOT NULL
      AND candidate_reference <> ''
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS janitor_local_object_reference_delete ON objects")
    execute("DROP TRIGGER IF EXISTS janitor_local_object_reference_update ON objects")
    execute("DROP TRIGGER IF EXISTS janitor_local_object_reference_insert ON objects")
    execute("DROP TRIGGER IF EXISTS janitor_local_activity_reference_delete ON activities")
    execute("DROP TRIGGER IF EXISTS janitor_local_activity_reference_update ON activities")
    execute("DROP TRIGGER IF EXISTS janitor_local_activity_reference_insert ON activities")
    execute("DROP FUNCTION IF EXISTS refresh_janitor_local_object_references()")
    execute("DROP FUNCTION IF EXISTS refresh_janitor_local_activity_reference()")
    drop(table(:janitor_local_references))
  end
end

# end of 20260820200000_add_janitor_local_reference_catalog.exs
