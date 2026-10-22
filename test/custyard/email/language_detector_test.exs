defmodule Custyard.Email.LanguageDetectorTest do
  use ExUnit.Case, async: true

  alias Custyard.Email.LanguageDetector

  @samples %{
    "en" =>
      "Hello, I have a problem with my account and the invoice is not showing. Could you please help?",
    "de" =>
      "Hallo, ich habe ein Problem mit meinem Konto und die Rechnung wird nicht angezeigt. Können Sie bitte helfen?",
    "fr" =>
      "Bonjour, j'ai un problème avec mon compte et la facture ne s'affiche pas. Pouvez-vous nous aider ?",
    "es" =>
      "Hola, tengo un problema con mi cuenta y la factura no se muestra. ¿Pueden ayudarme por favor?",
    "nl" =>
      "Hallo, ik heb een probleem met mijn account en de factuur wordt niet getoond. Kunnen jullie helpen?",
    "pt" =>
      "Olá, eu tenho um problema com a minha conta e a fatura não aparece. Vocês podem ajudar por favor?",
    "it" =>
      "Ciao, ho un problema con il mio account e la fattura non viene mostrata. Potete aiutarmi per favore?"
  }

  test "detects each supported language from a short support message" do
    for {code, text} <- @samples do
      assert LanguageDetector.detect(text) == code, "expected #{code} for #{inspect(text)}"
    end
  end

  test "answers nil for short, empty or non-text input" do
    assert LanguageDetector.detect("ok thanks") == nil
    assert LanguageDetector.detect("") == nil
    assert LanguageDetector.detect(nil) == nil
    assert LanguageDetector.detect("1234567890 1234567890 1234567890") == nil
  end

  test "answers nil when no language clearly leads" do
    assert LanguageDetector.detect(
             "Error code 0x8004 occurred at 14:02 UTC in module XYZ-42 build 7"
           ) ==
             nil
  end

  test "names codes" do
    assert LanguageDetector.name("de") == "German"
    assert LanguageDetector.name("xx") == "xx"
    assert "en" in LanguageDetector.languages()
  end
end
