defmodule Pleroma.Repo.Migrations.AssignAppUser do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE apps AS app
    SET user_id = token_owner.user_id,
        updated_at = NOW()
    FROM (
      SELECT DISTINCT ON (app_id) app_id, user_id
      FROM oauth_tokens
      WHERE app_id IS NOT NULL
        AND user_id IS NOT NULL
      ORDER BY app_id, inserted_at ASC, id ASC
    ) AS token_owner
    WHERE app.id = token_owner.app_id
      AND app.user_id IS NULL
    """)
  end

  def down, do: :ok
end
