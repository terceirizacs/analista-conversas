#!/bin/bash
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

ask() {
  jq -n --arg reason "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
}

# Bash: confirmar mv/rm/rmdir e leituras a credenciais
if [ "$TOOL" = "Bash" ]; then
  if echo "$COMMAND" | grep -qE '\b(mv|rm|rmdir)\b'; then
    ask "Requer confirmacao: mover/deletar requer aprovacao explicita do Tiago."
  fi
  if echo "$COMMAND" | grep -qE '\.env(\.|$|[[:space:]])'; then
    ask "Requer confirmacao: comando toca .env. Exibir conteudo pode vazar credenciais do conector Supabase."
  fi
fi

# Write/Edit: proteger base de conhecimento + conector + .env
if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  case "$FILE_PATH" in
    */.env|*/.env.local|*/.env.*.local)
      ask "Requer confirmacao: alterar arquivo .env (pode conter credenciais do conector Supabase)."
      ;;
    */CONECTOR-SUPABASE.md)
      ask "Requer confirmacao: CONECTOR-SUPABASE.md descreve o acesso ao banco real. Alterar requer aprovacao."
      ;;
    */INSTRUCOES.md|*/QUERIES-SQL.md|*/EXEMPLOS-DE-PERGUNTAS.md)
      ask "Requer confirmacao: arquivo de conhecimento canonico do Analista de Conversas. Alterar requer aprovacao."
      ;;
    */CLAUDE.md|*/AGENTS.md)
      ask "Requer confirmacao: CLAUDE.md/AGENTS.md. Alterar requer aprovacao."
      ;;
  esac
fi

exit 0
