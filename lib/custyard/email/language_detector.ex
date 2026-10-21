defmodule Custyard.Email.LanguageDetector do
  @moduledoc """
  Dependency-free language detection for customer mail, good enough to
  route and badge a conversation (spec-inbound-channels Phase 2,
  "language detection as an enrichment purpose").

  Scores the text's words against a short list of high-frequency function
  words per language and answers only when one language clearly wins:
  at least `@min_hits` matches and a lead over the runner-up. Anything
  shorter or more ambiguous is `nil`, never a guess. Languages: English,
  German, French, Spanish, Dutch, Portuguese, Italian.
  """

  @min_hits 3
  @min_chars 20

  @stopwords %{
    "en" => ~w(the and is are was were have has not with this that for you your from please thanks
         hello hi would could can will our we they been there their what when which),
    "de" => ~w(der die das und ist nicht ich sie wir mit für auf ein eine einen dem den haben
         hat wird können bitte danke hallo sehr noch auch aber oder wenn nach bei zu),
    "fr" => ~w(le la les et est pas je vous nous une des pour avec dans sur que qui ce cette
         mais merci bonjour notre votre sont été être avoir plus ils elle),
    "es" => ~w(el la los las y es no yo usted nosotros una por con para que del en como pero
         gracias hola nuestro su son sido ser tener más ellos ella también),
    "nl" => ~w(de het een en is niet ik wij jullie met voor van op dat die deze maar alvast
         bedankt hallo onze uw zijn worden kunnen graag ook nog naar bij),
    "pt" => ~w(o a os as e é não eu você nós uma por com para que do da em como mas obrigado
         olá nosso seu são foi ser ter mais eles ela também),
    "it" => ~w(il la lo gli le e è non io voi noi una per con che del della nel ma grazie
         ciao nostro suo sono stato essere avere più loro lei anche)
  }

  @sets Map.new(@stopwords, fn {code, words} -> {code, MapSet.new(words)} end)

  @doc "Supported ISO 639-1 codes."
  def languages, do: Map.keys(@stopwords) |> Enum.sort()

  @doc """
  Detect the language of `text`. Returns an ISO 639-1 code or `nil`.
  """
  @spec detect(term()) :: String.t() | nil
  def detect(text) when is_binary(text) and byte_size(text) >= @min_chars do
    words =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}']+/u, trim: true)

    scores =
      @sets
      |> Enum.map(fn {code, set} -> {code, Enum.count(words, &MapSet.member?(set, &1))} end)
      |> Enum.sort_by(fn {_code, hits} -> -hits end)

    case scores do
      [{code, best}, {_other, second} | _rest] when best >= @min_hits and best >= second * 1.5 ->
        code

      _ambiguous ->
        nil
    end
  end

  def detect(_text), do: nil

  @doc "Display name for a code (the code itself when unknown)."
  def name("en"), do: "English"
  def name("de"), do: "German"
  def name("fr"), do: "French"
  def name("es"), do: "Spanish"
  def name("nl"), do: "Dutch"
  def name("pt"), do: "Portuguese"
  def name("it"), do: "Italian"
  def name(code), do: code
end
