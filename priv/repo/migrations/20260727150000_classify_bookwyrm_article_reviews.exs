# Unfathomably BE
# ----------------
#
# File: 20260727150000_classify_bookwyrm_article_reviews.exs
#
# Purpose:
#   Keep BookWyrm reviews in the Books world when they use ActivityPub Article.
#
# Responsibilities:
#   - recognize the structural inReplyToBook review relationship
#   - preserve every other native-family classification rule
#   - rebuild the expression index whose values depend on the classifier
#
# This file intentionally does NOT identify BookWyrm by hostname, import a
# remote review backlog, or classify unrelated ActivityPub Articles as books.

defmodule Pleroma.Repo.Migrations.ClassifyBookwyrmArticleReviews do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @article_clause "WHEN short_type IN ('article', 'page') THEN 'longform'"

  @book_review_clause """
  WHEN COALESCE(data ->> 'inReplyToBook', '') <> ''
    OR extension_fields ? 'inReplyToBook' THEN 'books'
  #{@article_clause}
  """

  def up do
    replace_classifier(@article_clause, String.trim(@book_review_clause))
    rebuild_family_index()
  end

  def down do
    replace_classifier(String.trim(@book_review_clause), @article_clause)
    rebuild_family_index()
  end

  defp replace_classifier(old_clause, new_clause) do
    execute("""
    DO $migration$
    DECLARE
      current_definition text;
      updated_definition text;
    BEGIN
      current_definition :=
        pg_get_functiondef('unfathomably_native_family(jsonb)'::regprocedure);

      updated_definition :=
        replace(
          current_definition,
          #{dollar_quote(old_clause)},
          #{dollar_quote(new_clause)}
        );

      IF updated_definition = current_definition THEN
        RAISE EXCEPTION
          'unfathomably_native_family does not contain the expected classifier clause';
      END IF;

      EXECUTE updated_definition;
    END
    $migration$;
    """)
  end

  defp rebuild_family_index do
    execute("REINDEX INDEX CONCURRENTLY objects_native_family_recent_index")
  end

  defp dollar_quote(value) do
    "$classifier$#{value}$classifier$"
  end
end

# end of 20260727150000_classify_bookwyrm_article_reviews.exs
