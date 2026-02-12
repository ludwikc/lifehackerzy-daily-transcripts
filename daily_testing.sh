#!/bin/zsh
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
SCRIPT_DIR="${0:A:h}"
RCLONE_REMOTE="GoogleDrive:Craig"
LOCAL_DIR="${HOME}/craig-on-mikrus"
MP3_DIR="${LOCAL_DIR}/mp3"
TRANSCRIPTS_DIR="${LOCAL_DIR}/transcripts"
SUMMARIES_DIR="${LOCAL_DIR}/summaries"
PROMPTS_DIR="${SCRIPT_DIR}/prompts"

OPENAI_API_KEY_TESTING="${OPENAI_API_KEY_TESTING:-}"
CHATGPT_MODEL="gpt-4o-mini"

PROMPT_FILE_NAME="daily_summary_default.md"
LOG_FILE="${LOCAL_DIR}/transcript_testing_script.log"

usage() {
  cat <<EOF
Uzycie:
  ./daily_testing.sh [--prompt nazwa-promptu.md]

Przyklady:
  ./daily_testing.sh
  ./daily_testing.sh --prompt daily_summary_default.md
  ./daily_testing.sh --prompt /pelna/sciezka/do/promptu.md

Wymagane zmienne:
  OPENAI_API_KEY_TESTING
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      shift
      if [[ $# -eq 0 ]]; then
        print -- "ERROR: brak wartosci po --prompt"
        usage
        exit 1
      fi
      PROMPT_FILE_NAME="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -- "ERROR: nieznany argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "${PROMPT_FILE_NAME}" = /* ]]; then
  PROMPT_FILE="${PROMPT_FILE_NAME}"
else
  PROMPT_FILE="${PROMPTS_DIR}/${PROMPT_FILE_NAME}"
fi

if [[ ! -f "${PROMPT_FILE}" ]]; then
  print -- "ERROR: plik promptu nie istnieje: ${PROMPT_FILE}"
  exit 1
fi

CHATGPT_PROMPT="$(cat "${PROMPT_FILE}")"
if [[ -z "${CHATGPT_PROMPT}" ]]; then
  print -- "ERROR: plik promptu jest pusty: ${PROMPT_FILE}"
  exit 1
fi

# -----------------------------
# Logging and guards
# -----------------------------
log() {
  print -- "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  log "ERROR: command failed at line ${line_no}, exit code ${exit_code}"
}

trap 'on_error "$?" "$LINENO"' ERR

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "ERROR: missing required command: ${cmd}"
    exit 1
  fi
}

mkdir -p "${LOCAL_DIR}" "${MP3_DIR}" "${TRANSCRIPTS_DIR}" "${SUMMARIES_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Script started."
log "Prompt file: ${PROMPT_FILE}"

require_cmd rclone
require_cmd ffmpeg
require_cmd jq
require_cmd curl

if [[ -z "${OPENAI_API_KEY_TESTING}" ]]; then
  log "ERROR: OPENAI_API_KEY_TESTING is not set."
  exit 1
fi

# -----------------------------
# 1) Find and download only the newest AAC from Google Drive (no subfolders)
# -----------------------------
log "Finding newest AAC file on ${RCLONE_REMOTE} (no subfolders)."
LATEST_REMOTE_AAC="$(
  rclone lsjson "${RCLONE_REMOTE}" --files-only --max-depth 1 --include "*.aac" \
    | jq -r 'if length == 0 then empty else max_by(.ModTime).Path end'
)"

if [[ -z "${LATEST_REMOTE_AAC}" || "${LATEST_REMOTE_AAC}" == "null" ]]; then
  log "ERROR: no AAC files found on ${RCLONE_REMOTE}."
  exit 1
fi

log "Newest remote AAC: ${LATEST_REMOTE_AAC}"
DOWNLOADED_AAC="${LOCAL_DIR}/${LATEST_REMOTE_AAC:t}"
log "Downloading only newest file to ${DOWNLOADED_AAC}"
rclone copyto "${RCLONE_REMOTE}/${LATEST_REMOTE_AAC}" "${DOWNLOADED_AAC}" -P

if [[ ! -f "${DOWNLOADED_AAC}" ]]; then
  log "ERROR: downloaded file not found: ${DOWNLOADED_AAC}"
  exit 1
fi

# -----------------------------
# 2) Rename downloaded file if it matches pattern
# -----------------------------
TARGET_AAC="${DOWNLOADED_AAC}"
BASE_AAC="${DOWNLOADED_AAC:t}"
if [[ "${BASE_AAC}" =~ ^craig_[^_]+_([0-9]{4}-[0-9]{1,2}-[0-9]{1,2})_11-(2[9]|3[0-9])-[0-9]{1,2}\.aac$ ]]; then
  date_part="${match[1]}"
  RENAMED_AAC="${LOCAL_DIR}/Lifehackerzy-DailyCoaching-${date_part}.aac"
  if [[ "${DOWNLOADED_AAC}" != "${RENAMED_AAC}" ]]; then
    log "Renaming: ${BASE_AAC} -> ${RENAMED_AAC:t}"
    mv -f -- "${DOWNLOADED_AAC}" "${RENAMED_AAC}"
    TARGET_AAC="${RENAMED_AAC}"
  fi
else
  log "Filename does not match rename pattern, keeping original: ${BASE_AAC}"
fi

# -----------------------------
# 3) Convert only selected AAC -> MP3 (small size)
# -----------------------------
LATEST_MP3="${MP3_DIR}/${TARGET_AAC:t:r}.mp3"
log "Converting: ${TARGET_AAC:t} -> ${LATEST_MP3:t}"
ffmpeg -y -hide_banner -loglevel error \
  -stats \
  -i "${TARGET_AAC}" \
  -ac 1 \
  -ar 16000 \
  -codec:a libmp3lame \
  -qscale:a 9 \
  "${LATEST_MP3}"

if [[ ! -f "${LATEST_MP3}" ]]; then
  log "ERROR: MP3 file was not created: ${LATEST_MP3}"
  exit 1
fi
log "MP3 selected for transcription: ${LATEST_MP3:t}"

# -----------------------------
# 4) Whisper transcription
# -----------------------------
log "Sending MP3 to OpenAI transcription API."
WHISPER_JSON_FILE="${LOCAL_DIR}/_whisper_response_testing.json"
WHISPER_HTTP_CODE="$(curl -sS -o "${WHISPER_JSON_FILE}" -w "%{http_code}" -X POST "https://api.openai.com/v1/audio/transcriptions" \
  -H "Authorization: Bearer ${OPENAI_API_KEY_TESTING}" \
  -F file=@"${LATEST_MP3}" \
  -F model=whisper-1)"

if [[ "${WHISPER_HTTP_CODE}" -lt 200 || "${WHISPER_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: Whisper HTTP status ${WHISPER_HTTP_CODE}"
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi

if ! jq -e . "${WHISPER_JSON_FILE}" >/dev/null 2>&1; then
  log "ERROR: Whisper returned non-JSON response."
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi

TRANSCRIPT_TEXT="$(jq -r '.text // empty' "${WHISPER_JSON_FILE}")"
if [[ -z "${TRANSCRIPT_TEXT}" ]]; then
  log "ERROR: transcription is empty."
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi
TRANSCRIPT_TEXT_CLEAN="${TRANSCRIPT_TEXT}"
log "Transcription received."

TRANSCRIPT_FILE="${TRANSCRIPTS_DIR}/${TARGET_AAC:t:r}.txt"
print -- "${TRANSCRIPT_TEXT_CLEAN}" >| "${TRANSCRIPT_FILE}"
log "Transcript saved: ${TRANSCRIPT_FILE}"

# -----------------------------
# 5) Generate article with Chat Completions
# -----------------------------
log "Generating summary article with ChatGPT."
CHATGPT_PAYLOAD="$(jq -n \
  --arg model "${CHATGPT_MODEL}" \
  --arg system "${CHATGPT_PROMPT}" \
  --arg user "${TRANSCRIPT_TEXT_CLEAN}" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $user}
    ]
  }')"

CHATGPT_JSON_FILE="${LOCAL_DIR}/_chatgpt_response_testing.json"
CHATGPT_HTTP_CODE="$(curl -sS -o "${CHATGPT_JSON_FILE}" -w "%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
  -H "Authorization: Bearer ${OPENAI_API_KEY_TESTING}" \
  -H "Content-Type: application/json" \
  -d "${CHATGPT_PAYLOAD}")"

if [[ "${CHATGPT_HTTP_CODE}" -lt 200 || "${CHATGPT_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: ChatGPT HTTP status ${CHATGPT_HTTP_CODE}"
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

if ! jq -e . "${CHATGPT_JSON_FILE}" >/dev/null 2>&1; then
  log "ERROR: ChatGPT returned non-JSON response."
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

ARTICLE_TEXT="$(jq -r '.choices[0].message.content // empty' "${CHATGPT_JSON_FILE}")"
if [[ -z "${ARTICLE_TEXT}" ]]; then
  log "ERROR: no article text returned by ChatGPT."
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

PROMPT_BASENAME="${PROMPT_FILE:t:r}"
SUMMARY_FILE="${SUMMARIES_DIR}/${TARGET_AAC:t:r}-${PROMPT_BASENAME}.md"
print -- "${ARTICLE_TEXT}" >| "${SUMMARY_FILE}"
log "Summary saved: ${SUMMARY_FILE}"

log "Skipping Discord publish in testing mode."
print -- ""
print -- "==================== PODSUMOWANIE (${PROMPT_FILE:t}) ===================="
print -- "${ARTICLE_TEXT}"
print -- "========================== KONIEC PODSUMOWANIA =========================="
print -- ""

log "Script completed successfully."
