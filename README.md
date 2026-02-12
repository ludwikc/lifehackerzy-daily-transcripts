# lifehackerzy-daily-transcripts

Automatyzacja publikacji podsumowania 12:34 Daily Coaching na Discordzie Lifehackerów na podstawie najnowszego pliku `.aac` z Google Drive.

Skrypt `daily_manual.sh` wykonuje cały pipeline:
1. Pobiera najnowsze nagranie `.aac` z `GoogleDrive:Craig`.
2. Opcjonalnie zmienia nazwę pliku wg wzorca daty.
3. Konwertuje audio do `.mp3` (mono, 16 kHz, mały rozmiar).
4. Tworzy transkrypcję przez OpenAI Whisper (`whisper-1`).
5. Generuje podsumowanie Markdown przez Chat Completions (`gpt-4o-mini`).
6. Publikuje wpis jako nowy wątek na Discord Forum + dopisuje wiadomość follow-up.

## Wymagania

- `zsh`
- `rclone`
- `ffmpeg`
- `jq`
- `curl`
- dostęp do:
  - Google Drive skonfigurowanego w `rclone` jako `GoogleDrive:Craig`
  - OpenAI API
  - Discord Bot API (bot z uprawnieniami do tworzenia wątków i wysyłania wiadomości)

## Zmienne środowiskowe

Wymagane:
- `OPENAI_API_KEY` - klucz API OpenAI
- `DISCORD_BOT_TOKEN` - token bota Discord
- `DISCORD_FORUM_CHANNEL_ID` - ID kanału forum, gdzie tworzony jest nowy wątek

Opcjonalne/domyślne w skrypcie:
- `RCLONE_REMOTE=GoogleDrive:Craig`
- `LOCAL_DIR=$HOME/craig-on-mikrus`
- `NEXT_DAILY_CHANNEL_ID=1120658406160732160`
- `MAX_DISCORD_CHARS=1800`
- `CHATGPT_MODEL=gpt-4o-mini`

## Jak uruchomić

```bash
chmod +x daily_manual.sh
OPENAI_API_KEY=... \
DISCORD_BOT_TOKEN=... \
DISCORD_FORUM_CHANNEL_ID=... \
./daily_manual.sh
```

## Co powstaje lokalnie

W `LOCAL_DIR` (domyślnie `~/craig-on-mikrus`):
- `mp3/` - przekonwertowane pliki audio
- `transcripts/` - transkrypcje `.txt`
- `transcript_script.log` - log działania
- pliki tymczasowe odpowiedzi API:
  - `_whisper_response.json`
  - `_chatgpt_response.json`
  - `_chatgpt_shorten_response.json` (jeśli potrzebne skrócenie)
  - `_discord_create_response.json`

## Logika publikacji i limity

- Skrypt pilnuje limitu Discorda: `MAX_DISCORD_CHARS` (domyślnie 1800).
- Jeśli artykuł jest za długi, skrypt robi dodatkowe żądanie o skrócenie.
- Jeśli nadal jest za długi, tekst jest obcinany do limitu znaków.
- Po utworzeniu wątku wysyłana jest dodatkowa wiadomość:
  `Następny <#NEXT_DAILY_CHANNEL_ID> odbędzie się jak zwykle jutro o 12:34`

## Obsługa błędów

- `set -euo pipefail` + `trap ERR` z logowaniem linii błędu.
- Walidacja obecności wymaganych komend i zmiennych środowiskowych.
- Walidacja kodów HTTP i poprawności JSON dla OpenAI i Discord API.
- W razie błędu skrypt kończy działanie z kodem `!= 0`.

## Uwagi

- Renaming działa tylko gdy nazwa wejściowa pasuje do wzorca:
  `craig_*_YYYY-M-D_11-29..39-*.aac`
- Obecnie skrypt bierze tylko pliki z katalogu głównego `RCLONE_REMOTE` (`--max-depth 1`), bez podfolderów.
- Plik `README.md` opisuje stan zgodny z aktualnym `daily_manual.sh`.
