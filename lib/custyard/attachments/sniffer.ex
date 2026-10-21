defmodule Custyard.Attachments.Sniffer do
  @moduledoc """
  Content type from the first bytes of a file, independent of what the
  sender declared. The result decides how the download endpoint serves the
  file; anything unrecognised is `application/octet-stream`.
  """

  @text_probe 512

  @spec sniff(binary()) :: String.t()
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  def sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(<<"%PDF-", _::binary>>), do: "application/pdf"
  def sniff(<<"PK", 0x03, 0x04, _::binary>>), do: "application/zip"
  def sniff(<<0x1F, 0x8B, _::binary>>), do: "application/gzip"
  def sniff(<<"7z", 0xBC, 0xAF, 0x27, 0x1C, _::binary>>), do: "application/x-7z-compressed"
  def sniff(<<"Rar!", 0x1A, 0x07, _::binary>>), do: "application/vnd.rar"

  def sniff(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _::binary>>),
    do: "application/x-ole-storage"

  def sniff(<<"<?xml", _::binary>>), do: "application/xml"

  def sniff(bytes) when is_binary(bytes) do
    probe = binary_part(bytes, 0, min(byte_size(bytes), @text_probe))

    if String.valid?(probe) and not String.contains?(probe, <<0>>),
      do: "text/plain",
      else: "application/octet-stream"
  end
end
