defmodule Pleroma.Repo.Migrations.AddGroupFollowNotifications do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    """
    alter type notification_type add value if not exists 'group_follow'
    """
    |> execute()

    """
    alter type notification_type add value if not exists 'group_follow_request'
    """
    |> execute()

    alter table(:users) do
      add_if_not_exists(:group_join_notifications, :boolean, default: true, null: false)
    end
  end

  def down do
    alter table(:users) do
      remove_if_exists(:group_join_notifications, :boolean)
    end
  end
end
