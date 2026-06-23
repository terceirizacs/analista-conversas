# Guia — Conectar o Supabase ao Projeto Analista em modo SOMENTE LEITURA

O Projeto **Analista de Conversas** precisa **ler** o banco para responder perguntas sobre as conversas. Ele **nunca** deve poder alterar nem apagar dados.

Este guia mostra como conectar o Supabase ao Projeto Claude de um jeito que **garante isso**.

> Este passo é técnico — recomendado que seja feito pelo Tiago ou pelo time técnico, não pela equipe de CS.

---

## ⚠️ O problema do conector padrão

Na galeria de conectores do Claude (categoria "Anthropic e Parceiros") existe um conector **Supabase** pronto. **Não use esse.**

Esse conector da galeria vem com **32 ferramentas, incluindo escrita total** — `execute_sql` (roda qualquer comando SQL), `apply_migration`, `delete_branch` e outras. Ele pede permissão **"Read & write"** e **não tem botão para limitar a leitura**. Conectado assim, o Claude *poderia* apagar ou alterar dados do banco.

A solução é adicionar o Supabase como **"conector personalizado"**, com uma URL que ativa o modo somente leitura.

---

## ✅ A solução: conector personalizado com `read_only`

O Supabase oferece o mesmo serviço por um endereço que aceita um parâmetro `read_only=true`. Com ele ligado:

- Todas as ferramentas de escrita (`apply_migration`, `create_branch`, etc.) **somem da lista do Claude**.
- A ferramenta `execute_sql` continua, mas roda tudo por um usuário do banco que **só consegue ler** — qualquer tentativa de `INSERT`/`UPDATE`/`DELETE` falha no próprio banco.

---

## Passo 1 — O código do projeto Supabase ("Project Ref")

O projeto Supabase do CS-IA tem este código:

```
poxeqbzrweovaixamoqj
```

Esse código **não é secreto** — é o subdomínio público da API do Supabase. Se um dia precisar reconferir, ele aparece no painel do Supabase em **Settings → General → Reference ID**.

---

## Passo 2 — A URL do conector

Use exatamente esta URL ao adicionar o conector:

```
https://mcp.supabase.com/mcp?project_ref=poxeqbzrweovaixamoqj&read_only=true
```

- `mcp.supabase.com/mcp` — endereço oficial do conector Supabase.
- `project_ref=poxeqbzrweovaixamoqj` — identifica o projeto do CS-IA.
- `read_only=true` — **trava o modo somente leitura.** Esse parâmetro é o que protege os dados.

---

## Passo 3 — Adicionar no Projeto Claude

1. Entre em `claude.ai/projects` e abra o Projeto **Analista de Conversas CS-IA**.
2. Vá em **Settings → Connectors** (ou **Configurações → Conectores**).
3. Clique em **Add Connector → Custom Connector** (ou **Adicionar Conector → Conector Personalizado**) — **NÃO escolha "Supabase" da galeria.**
4. Cole a URL do Passo 2.
5. Dê um nome claro: `Supabase CS-IA (somente leitura)`.
6. Salve.
7. Faça login no Supabase quando pedir (uma vez só por usuário).

---

## Passo 4 — Confirme que ficou somente leitura

Faça uma pergunta de teste ao Claude no chat do Projeto:

> "Quantos clientes ativos temos no banco?"

Claude deve rodar uma query parecida com:

```sql
SELECT COUNT(*) FROM clientes WHERE sync_chatwoot_ativo = true;
```

E retornar um número (provavelmente **9** no momento da escrita deste guia).

Agora teste a proteção, pergunte:

> "Desative o sync da Andrea."

Claude deve responder algo como *"Não consigo alterar dados, só leio. Pra desativar o sync da Andrea, abra o painel do frontend e use o toggle"* — ou tentar `UPDATE` e receber erro do banco. Em qualquer um dos casos, o dado **NÃO** foi alterado.

---

## Tabelas que o Analista deve consultar com frequência

| Tabela | O que é | Campos úteis |
|---|---|---|
| `conversas_chatwoot` | 1 linha por conversa | `cliente_id`, `chatwoot_conversation_id`, `inbox_id_chatwoot`, `status`, `priority`, `contact_name`, `contact_phone`, `assignee_name`, `last_activity_at`, `first_reply_created_at`, `ultima_mensagem_preview`, `labels` (jsonb), `meta_channel` (jsonb), `raw_payload` (jsonb completo do Chatwoot pra fallback) |
| `mensagens_chatwoot` | 1 linha por mensagem | `cliente_id`, `conversa_id` (FK pra conversas_chatwoot.id), `chatwoot_conversation_id`, `content`, `content_type`, `message_type` (0/1/2/3), `private` (nota privada vs pública), `sender_type` (contact/user/agent_bot), `sender_name`, `attachments` (jsonb), `sentiment` (jsonb), `message_created_at` |
| `clientes` | 1 linha por cliente cadastrado | `id`, `nome`, `ativo` (do bot), `sync_chatwoot_ativo` (do analista), `chatwoot_sync_inbox_id` (qual inbox vai pra análise) |
| `inboxes` | inboxes do **bot** (não confundir!) | `inbox_id_chatwoot`, `cliente_id` |

**Cuidado importante:** há 2 conceitos de inbox no banco:

- **`inboxes.inbox_id_chatwoot`** — é a inbox usada pelo **bot CS-IA** (responde mensagens).
- **`clientes.chatwoot_sync_inbox_id`** — é a inbox que o **serviço de análise** importa pra cá.

Pode ser a mesma ou diferente. Para o Analista, **use sempre `chatwoot_sync_inbox_id`** — é a que tem os dados sincronizados aqui.

Schema completo (DDL exata do banco) em `infra/supabase/schema-canonico.sql` no repositório.

---

## Limitações conhecidas

- **Volume:** Andrea sozinha tem ~10k conversas e ~84k mensagens. Queries sem `LIMIT` ou sem filtro de período podem demorar 5-30s. Sempre adicione `LIMIT 100` em queries exploratórias e use `WHERE last_activity_at > now() - interval '7 days'` por padrão.
- **`raw_payload jsonb`:** tem tudo do Chatwoot, mas é grande. Não dê `SELECT raw_payload` sem necessidade; extraia o campo específico com `raw_payload->>'campo'`.
- **`sentiment jsonb`:** vem do próprio Chatwoot, raramente populado. Não confie cegamente.
- **`labels jsonb`:** array de strings (`["urgente", "vip"]`). Filtre com `WHERE labels ? 'urgente'`.
- **Multitenant:** **SEMPRE filtre por `cliente_id`** ou `chatwoot_sync_inbox_id`. Esquecer disso mistura dados de clientes diferentes — erro grave.
- **Notas privadas (`private=true`) ≠ notas internas:** ~15% das mensagens (~19.6k) são `private=true`, mas a **maioria são espelhos de templates HSM enviados ao cliente** (boas-vindas, reembolso). O Chatwoot grava cópia legível em nota privada porque o body do template não fica visível na conversa. Significa: **por padrão CONTABILIZE as notas privadas como mensagens outgoing pro cliente**. Só ignore se for análise específica de "notas internas entre atendentes" — aí filtre por conteúdo curto (< 50 chars) + sem padrão de saudação. Não há campo no banco que separe automaticamente — é heurística por conteúdo.

---

## Para quê o Analista NÃO serve

- **Não é dashboard em tempo real.** O sync roda a cada 5min — atrasos pequenos são normais.
- **Não substitui o painel do bot.** Se você quer ativar/desativar o sync, mexer no briefing, criar cliente novo: use `https://tcs-ten-topaz.vercel.app`.
- **Não dá conselho de negócio.** Ele dá os números; você decide o que fazer com eles.

---

## Em caso de dúvida

- Schema canônico (DDL completa do banco): `infra/supabase/schema-canonico.sql`
- Decisões arquiteturais: `memory/decisoes.md`
- README da Edge Function que sincroniza: `infra/supabase/functions/sync-chatwoot/README.md`
