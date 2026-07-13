defmodule Custyard.IntakeSourceTest do
  use Custyard.DataCase, async: true

  alias Custyard.IntakeSource

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with key and name" do
      changeset =
        IntakeSource.changeset(%IntakeSource{}, build_intake_source(key: "landing-page"))

      assert changeset.valid?
    end

    test "requires key and name" do
      changeset = IntakeSource.changeset(%IntakeSource{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).key
      assert "can't be blank" in errors_on(changeset).name
    end

    test "accepts valid key formats" do
      for key <- ["a", "landing-page", "cta_2", "0abc", String.duplicate("a", 50)] do
        changeset = IntakeSource.changeset(%IntakeSource{}, build_intake_source(key: key))
        assert changeset.valid?, "expected key #{inspect(key)} to be valid"
      end
    end

    test "rejects invalid key formats" do
      for key <- [
            "Upper",
            "has space",
            "-leading",
            "_leading",
            "é",
            String.duplicate("a", 51),
            # ^/$ anchors would let $ match before a trailing newline
            "valid-key\n"
          ] do
        changeset = IntakeSource.changeset(%IntakeSource{}, build_intake_source(key: key))
        refute changeset.valid?, "expected key #{inspect(key)} to be invalid"
        assert "has invalid format" in errors_on(changeset).key
      end
    end

    test "rejects invalid mode" do
      changeset = IntakeSource.changeset(%IntakeSource{}, build_intake_source(mode: :hidden))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).mode
    end

    test "accepts headline, intro_copy, and questions at exactly their caps" do
      questions =
        [
          %{
            "question" => String.duplicate("q", 200),
            "answer" => String.duplicate("a", 2000)
          }
          | for(i <- 2..20, do: %{"question" => "q#{i}", "answer" => "a#{i}"})
        ]

      changeset =
        IntakeSource.changeset(
          %IntakeSource{},
          build_intake_source(
            headline: String.duplicate("h", 200),
            intro_copy: String.duplicate("i", 2000),
            questions: questions
          )
        )

      assert changeset.valid?
    end

    test "caps headline at 200 and intro_copy at 2000 chars" do
      changeset =
        IntakeSource.changeset(
          %IntakeSource{},
          build_intake_source(
            headline: String.duplicate("h", 201),
            intro_copy: String.duplicate("i", 2001)
          )
        )

      refute changeset.valid?
      assert "should be at most 200 character(s)" in errors_on(changeset).headline
      assert "should be at most 2000 character(s)" in errors_on(changeset).intro_copy
    end

    test "enforces unique key" do
      existing = insert_intake_source()

      assert {:error, changeset} =
               %IntakeSource{}
               |> IntakeSource.changeset(build_intake_source(key: existing.key))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).key
    end
  end

  describe "update_changeset/2" do
    test "never casts the key" do
      source = insert_intake_source(key: "original")

      for attrs <- [%{key: "other", name: "Renamed"}, %{"key" => "other", "name" => "Renamed"}] do
        changeset = IntakeSource.update_changeset(source, attrs)

        assert changeset.valid?
        refute Map.has_key?(changeset.changes, :key)
        assert Ecto.Changeset.fetch_field!(changeset, :key) == "original"
      end
    end

    test "still enforces content validations" do
      source = insert_intake_source()

      changeset = IntakeSource.update_changeset(source, %{name: nil})
      assert "can't be blank" in errors_on(changeset).name

      changeset =
        IntakeSource.update_changeset(source, %{headline: String.duplicate("h", 201)})

      assert "should be at most 200 character(s)" in errors_on(changeset).headline
    end
  end

  describe "questions validation" do
    test "accepts a valid Q&A list and round-trips through the database" do
      questions = [
        %{"question" => "What is this?", "answer" => "A public intake page."},
        %{"question" => "Who reads it?", "answer" => "The operator."}
      ]

      source = insert_intake_source(questions: questions)
      assert Repo.reload!(source).questions == questions
    end

    test "rejects more than 20 entries" do
      questions = for i <- 1..21, do: %{"question" => "q#{i}", "answer" => "a#{i}"}

      changeset =
        IntakeSource.changeset(%IntakeSource{}, build_intake_source(questions: questions))

      refute changeset.valid?
      assert "must have at most 20 entries" in errors_on(changeset).questions
    end

    test "rejects entries with unknown keys" do
      questions = [%{"question" => "q", "answer" => "a", "html" => "<script>"}]

      changeset =
        IntakeSource.changeset(%IntakeSource{}, build_intake_source(questions: questions))

      refute changeset.valid?
    end

    test "rejects entries missing question or answer" do
      for entry <- [%{"question" => "q"}, %{"answer" => "a"}, %{}] do
        changeset =
          IntakeSource.changeset(%IntakeSource{}, build_intake_source(questions: [entry]))

        refute changeset.valid?, "expected #{inspect(entry)} to be invalid"
      end
    end

    test "rejects oversized question or answer" do
      too_long_question = [
        %{"question" => String.duplicate("q", 201), "answer" => "a"}
      ]

      too_long_answer = [
        %{"question" => "q", "answer" => String.duplicate("a", 2001)}
      ]

      for questions <- [too_long_question, too_long_answer] do
        changeset =
          IntakeSource.changeset(%IntakeSource{}, build_intake_source(questions: questions))

        refute changeset.valid?
      end
    end

    test "rejects non-string question or answer values" do
      changeset =
        IntakeSource.changeset(
          %IntakeSource{},
          build_intake_source(questions: [%{"question" => 1, "answer" => "a"}])
        )

      refute changeset.valid?
    end
  end

  describe "link fields" do
    test "accepts an http/https link_url with a title on create and update" do
      attrs = build_intake_source(link_title: "Acme", link_url: "https://acme.example/product")

      changeset = IntakeSource.changeset(%IntakeSource{}, attrs)
      assert changeset.valid?

      source = insert_intake_source()

      update =
        IntakeSource.update_changeset(source, %{
          name: source.name,
          link_title: "Acme",
          link_url: "http://acme.example"
        })

      assert update.valid?
    end

    test "rejects non-http(s) and malformed link_url values on both changesets" do
      source = insert_intake_source()

      for url <- [
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://acme.example",
            "acme.example",
            "/relative/path",
            "https://",
            "not a url"
          ] do
        changeset =
          IntakeSource.changeset(%IntakeSource{}, build_intake_source(link_url: url))

        refute changeset.valid?, "expected link_url #{inspect(url)} to be invalid on create"
        assert "must be an http or https URL" in errors_on(changeset).link_url

        update = IntakeSource.update_changeset(source, %{name: source.name, link_url: url})
        refute update.valid?, "expected link_url #{inspect(url)} to be invalid on update"
        assert "must be an http or https URL" in errors_on(update).link_url
      end
    end

    test "caps link_title at 80 chars" do
      changeset =
        IntakeSource.changeset(
          %IntakeSource{},
          build_intake_source(link_title: String.duplicate("t", 81))
        )

      refute changeset.valid?
      assert "should be at most 80 character(s)" in errors_on(changeset).link_title
    end

    test "link fields round-trip through the database" do
      source =
        insert_intake_source(link_title: "Acme", link_url: "https://acme.example")

      reloaded = Repo.reload!(source)
      assert reloaded.link_title == "Acme"
      assert reloaded.link_url == "https://acme.example"
    end
  end

  describe "link?/1" do
    test "true only when both title and url are present and non-blank" do
      assert IntakeSource.link?(%IntakeSource{
               link_title: "Acme",
               link_url: "https://acme.example"
             })

      refute IntakeSource.link?(%IntakeSource{link_title: "Acme", link_url: nil})
      refute IntakeSource.link?(%IntakeSource{link_title: nil, link_url: "https://a.example"})
      refute IntakeSource.link?(%IntakeSource{link_title: "  ", link_url: "https://a.example"})
      refute IntakeSource.link?(%IntakeSource{link_title: nil, link_url: nil})
    end

    test "nil source (deleted) is false" do
      refute IntakeSource.link?(nil)
    end
  end

  describe "key_format/0" do
    test "matches the conversations.intake_source_key format" do
      assert Regex.match?(IntakeSource.key_format(), "landing-page")
      refute Regex.match?(IntakeSource.key_format(), "Landing Page")
    end
  end
end
