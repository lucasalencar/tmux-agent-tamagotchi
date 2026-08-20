# shellcheck shell=bash
#
# Shared state-icon resolution. Callers populate the TAMA_ICON_* inputs either
# from individual option reads or from a batched status-line query.

# shellcheck disable=SC2034  # resolved globals are read by the sourcing command
tama_state_icons_resolve() {
  case "$TAMA_ICON_SET" in
    pets)
      TAMA_GLYPH_RUNNING='🐥' TAMA_GLYPH_WAITING='🍼' TAMA_GLYPH_BACKGROUND='🥚'
      TAMA_GLYPH_IDLE='😴' TAMA_GLYPH_ERROR='💀'
      ;;
    ascii)
      TAMA_GLYPH_RUNNING='*' TAMA_GLYPH_WAITING='?' TAMA_GLYPH_BACKGROUND='+'
      TAMA_GLYPH_IDLE='.' TAMA_GLYPH_ERROR='!'
      ;;
    *)
      TAMA_GLYPH_RUNNING='●' TAMA_GLYPH_WAITING='◐' TAMA_GLYPH_BACKGROUND='⚙'
      TAMA_GLYPH_IDLE='○' TAMA_GLYPH_ERROR='✕'
      ;;
  esac

  [ "$TAMA_ICON_HAS_RUNNING" = 0 ] || TAMA_GLYPH_RUNNING="$TAMA_ICON_RUNNING"
  [ "$TAMA_ICON_HAS_WAITING" = 0 ] || TAMA_GLYPH_WAITING="$TAMA_ICON_WAITING"
  [ "$TAMA_ICON_HAS_BACKGROUND" = 0 ] || TAMA_GLYPH_BACKGROUND="$TAMA_ICON_BACKGROUND"
  [ "$TAMA_ICON_HAS_IDLE" = 0 ] || TAMA_GLYPH_IDLE="$TAMA_ICON_IDLE"
  [ "$TAMA_ICON_HAS_ERROR" = 0 ] || TAMA_GLYPH_ERROR="$TAMA_ICON_ERROR"
}
