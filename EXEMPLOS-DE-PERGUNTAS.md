# Exemplos de Perguntas — Analista de Conversas

Casos de uso reais que o operador de CS faz ao Analista. Cada exemplo tem:

1. **Pergunta natural** (como o operador escreve, em PT-BR informal)
2. **Query SQL** que o Analista deve montar (validada contra o banco em 2026-05-28)
3. **Resumo do resultado esperado** (formato de resposta ao usuario)

Schema-alvo: `conversas_chatwoot` e `mensagens_chatwoot` (ver `schema-canonico.sql`). Banco em 2026-05-28: **18.643 conversas / 130.725 mensagens / 9 clientes**. Cresceu muito desde então — a Andrea sozinha passou de 20 mil conversas e são 16 clientes hoje; lista viva e volumes na tabela canônica em `infra/CLAUDE.md`.

**Convencoes:**
- Filtrar SEMPRE por `cliente_id` quando a pergunta menciona um cliente especifico.
- `message_type`: `0` = mensagem do contato, `1` = agente humano ou bot, `2` = evento de sistema, `3` = template (WhatsApp HSM).
- `status`: `open` / `pending` / `resolved` / `snoozed`. 99% das conversas estao `resolved` no historico — atenticao quando o operador pedir "abertas".
- Para metricas de tempo de resposta, **sempre filtrar `first_reply_created_at > created_at`** — ha ~9.4k linhas com `first_reply_created_at <= created_at` (provavelmente quirks do Chatwoot ou fallback do handler).

---

## Categoria: Volume & Tendencia

### 1. "Quantas conversas a Andrea recebeu essa semana?"

**Pergunta natural:** "quantas conversas a andrea recebeu nos ultimos 7 dias?"

**SQL:**
```sql
SELECT
  DATE_TRUNC('day', created_at)::date AS dia,
  COUNT(*) AS novas_conversas
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Andrea%' LIMIT 1)
  AND created_at >= (now() - interval '7 days')
GROUP BY dia
ORDER BY dia DESC;
```

**Resposta esperada (formato pro operador):**
> Nos ultimos 7 dias a Andrea recebeu **2.589 conversas novas**:
>
> | Dia | Novas |
> |---|---|
> | 28/05 | 491 |
> | 27/05 | 519 |
> | 26/05 | 525 |
> | 25/05 | 535 |
> | 24/05 | 55 (sabado) |
> | 23/05 | 66 (sexta) |
> | 22/05 | 418 |
>
> **Observacao:** fim de semana cai pra ~10% do volume de dias uteis. Media semanal: ~370/dia.

---

### 2. "Qual cliente teve mais conversas no mes passado?"

**Pergunta natural:** "ranking de clientes por volume de conversas em maio"

**SQL:**
```sql
SELECT
  c.nome AS cliente,
  COUNT(*) AS conversas,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
WHERE cc.created_at >= '2026-05-01'
  AND cc.created_at < '2026-06-01'
GROUP BY c.nome
ORDER BY conversas DESC;
```

**Resposta esperada:** ranking ordenado com totais e percentuais. Para o dataset atual, Andrea = 54%, segundo lugar (Rafa Bueno) = ~10%.

---

## Categoria: Conteudo

### 3. "Sobre o que os clientes mais reclamam?"

**Pergunta natural:** "principais temas das mensagens dos clientes essa semana"

**SQL (busca por buckets tematicos curados):**
```sql
SELECT
  COUNT(*) FILTER (WHERE content ILIKE '%reembolso%' OR content ILIKE '%devolu%')   AS reembolso,
  COUNT(*) FILTER (WHERE content ILIKE '%prazo%' OR content ILIKE '%demor%' OR content ILIKE '%atras%') AS prazo,
  COUNT(*) FILTER (WHERE content ILIKE '%cancela%')                                  AS cancelar,
  COUNT(*) FILTER (WHERE content ILIKE '%acesso%' OR content ILIKE '%senha%' OR content ILIKE '%login%') AS acesso,
  COUNT(*) FILTER (WHERE content ILIKE '%boleto%' OR content ILIKE '%paga%' OR content ILIKE '%pix%')    AS pagamento
FROM mensagens_chatwoot
WHERE message_type = 0
  AND message_created_at >= (now() - interval '7 days')
  AND content IS NOT NULL;
```

**Resposta esperada (numeros reais do dataset historico):**
> Os 5 principais temas das mensagens dos clientes (todo o historico):
>
> 1. **Acesso/Senha/Login** — 1.136 menc oes (de longe o tema #1)
> 2. **Pagamento (boleto/pix)** — 604
> 3. **Prazo/Demora/Atraso** — 441
> 4. **Cancelamento** — 429
> 5. **Reembolso/Devolucao** — 136
>
> **Insight:** problemas de acesso a plataforma sao quase 2x o segundo tema. Recomendo revisar o procedimento de recuperacao de senha e a base de conhecimento sobre primeiro acesso.

---

### 4. "Quais sao as palavras mais usadas pelos clientes?"

**Pergunta natural:** "top 20 palavras-chave nas mensagens dos clientes mes passado"

**SQL:**
```sql
WITH palavras AS (
  SELECT lower(unnest(regexp_split_to_array(content, '\s+'))) AS palavra
  FROM mensagens_chatwoot
  WHERE message_type = 0
    AND content IS NOT NULL
    AND message_created_at >= (now() - interval '30 days')
)
SELECT palavra, COUNT(*) AS frequencia
FROM palavras
WHERE LENGTH(palavra) > 4
  AND palavra NOT IN ('para','muito','quando','porque','sobre','agora','tudo','obrigada','obrigado','tambem','também','estou','estamos','consigo','poderia','queria','gostaria','minha','tenho','tinha','fazer','dizer','vocês','vocês.','vocês,')
GROUP BY palavra
ORDER BY frequencia DESC
LIMIT 20;
```

**Resposta esperada (validada em 2026-05-28):**
> Top palavras (ultimos 30 dias):
> 1. **curso** — 1.042
> 2. **ainda** — 823
> 3. **pamela** — 645 (nome da persona da Andrea)
> 4. **tarde** — 555
> 5. **quero** — 488
> 6. **preciso** — 427
> 7. **tempo** — 395
> 8. **aulas** — 391
> 9. **acessar** — 386
> 10. **acesso** — 360
>
> **Insight:** "acessar" + "acesso" + "entrar" + "plataforma" combinados = 1.361. Confirma o tema dominante (acesso a plataforma).

---

## Categoria: Status & Backlog

### 5. "Quantas conversas estao em aberto agora?"

**Pergunta natural:** "tem quantas conversas em aberto no momento?"

**SQL:**
```sql
SELECT
  c.nome AS cliente,
  COUNT(*) FILTER (WHERE cc.status = 'open')      AS abertas,
  COUNT(*) FILTER (WHERE cc.status = 'pending')   AS pendentes,
  COUNT(*) FILTER (WHERE cc.status = 'snoozed')   AS snoozed,
  COUNT(*) FILTER (WHERE cc.status = 'resolved')  AS resolvidas,
  COUNT(*)                                         AS total
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
GROUP BY c.nome
ORDER BY abertas DESC;
```

**Resposta esperada:**
> **187 conversas abertas no total** (e mais 2 pendentes). Distribuicao:
>
> | Cliente | Abertas | Pendentes |
> |---|---|---|
> | Andrea Vermont | 79 | 0 |
> | Rafa Bueno | ~50 | 1 |
> | ... | ... | ... |
>
> Cliente com mais backlog: **Andrea (79 abertas)**. Pode valer atribuir uma frente extra.

---

### 6. "Quais conversas estao paradas ha mais de 7 dias?"

**Pergunta natural:** "ha quanto tempo ta o lead esperando? me mostra as mais antigas em aberto"

**SQL:**
```sql
SELECT
  c.nome AS cliente,
  cc.contact_name,
  cc.contact_phone,
  cc.last_activity_at,
  age(now(), cc.last_activity_at) AS aguardando_ha
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
WHERE cc.status IN ('open', 'pending')
  AND cc.last_activity_at < (now() - interval '7 days')
ORDER BY cc.last_activity_at ASC
LIMIT 30;
```

**Resposta esperada:** lista das 30 conversas mais paradas, com nome do contato, cliente, e quanto tempo faz desde a ultima atividade. Util pra acionamento manual.

---

## Categoria: Performance & SLA

### 7. "Qual o tempo medio de resposta da Andrea esse mes?"

**Pergunta natural:** "tempo medio que o atendimento da andrea demora pra responder cliente?"

**SQL (com filtro defensivo contra dados quirky do Chatwoot):**
```sql
SELECT
  ROUND(AVG(EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/60)::numeric, 0) AS tmr_minutos_media,
  ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/60)::numeric, 0) AS tmr_minutos_mediana,
  COUNT(*) AS amostra
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Andrea%' LIMIT 1)
  AND first_reply_created_at IS NOT NULL
  AND first_reply_created_at > created_at  -- filtro contra quirks
  AND created_at >= (now() - interval '30 days');
```

**Resposta esperada:**
> Nos ultimos 30 dias, a Andrea respondeu **em media 1.462 minutos (~24h)** apos a primeira mensagem do cliente. Mediana e menor que a media (cauda longa de conversas que demoraram dias). Amostra: 9.259 conversas com dados validos.
>
> **Nota tecnica:** 50% das conversas tem `first_reply_created_at == created_at` no banco (sem janela mensuravel — provavelmente caso de auto-resposta ou primeira msg ja sendo do agente). Esse filtro foi excluido pra nao distorcer a media pra zero.

---

### 8. "Em qual horario o cliente mais escreve?"

**Pergunta natural:** "qual o pico de mensagens recebidas durante o dia?"

**SQL:**
```sql
SELECT
  EXTRACT(HOUR FROM message_created_at AT TIME ZONE 'America/Sao_Paulo')::int AS hora,
  COUNT(*) AS mensagens
FROM mensagens_chatwoot
WHERE message_type = 0  -- so do contato
  AND message_created_at >= (now() - interval '30 days')
GROUP BY hora
ORDER BY hora;
```

**Resposta esperada:** tabela hora x mensagens. Util pra dimensionar plantao de atendimento. Em CS B2C historicamente o pico fica entre 19h-22h (depois do trabalho).

---

## Categoria: Conversas Longas

### 9. "Quais conversas tiveram mais idas e vindas?"

**Pergunta natural:** "me mostra as conversas mais longas da andrea — pode ter algo de errado"

**SQL:**
```sql
SELECT
  cc.chatwoot_conversation_id,
  cc.contact_name,
  cc.contact_phone,
  cc.status,
  cc.created_at::date AS abriu_em,
  COUNT(mc.id) AS qtd_mensagens,
  cc.ultima_mensagem_preview
FROM conversas_chatwoot cc
JOIN mensagens_chatwoot mc ON mc.conversa_id = cc.id
WHERE cc.cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Andrea%' LIMIT 1)
GROUP BY cc.id, cc.chatwoot_conversation_id, cc.contact_name, cc.contact_phone, cc.status, cc.created_at, cc.ultima_mensagem_preview
ORDER BY qtd_mensagens DESC
LIMIT 10;
```

**Resposta esperada (top 10 reais validados):**
> Conversas com mais mensagens (Andrea, todo o historico):
>
> | Contato | Msgs | Status | Ultima mensagem |
> |---|---|---|---|
> | Sueli Lopes | 209 | resolved | (preview) |
> | Madalena | 190 | resolved | (preview) |
> | Flavia | 179 | resolved | (preview) |
> | Willian | 161 | resolved | (preview) |
> | Kátia Thomazine | 157 | resolved | (preview) |
>
> Conversas com 100+ msgs geralmente sao caso "dificil" — vale revisar o handoff ou a base de conhecimento.

---

## Categoria: Attachments & Multimedia

### 10. "Os clientes mandam muito audio?"

**Pergunta natural:** "qual % das mensagens dos clientes vem por audio?"

**SQL:**
```sql
WITH base AS (
  SELECT
    COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"audio"}]'::jsonb) AS audios,
    COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"image"}]'::jsonb) AS imagens,
    COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"file"}]'::jsonb)  AS arquivos,
    COUNT(*) FILTER (WHERE attachments = '[]'::jsonb)                       AS so_texto,
    COUNT(*) AS total
  FROM mensagens_chatwoot
  WHERE message_type = 0  -- so do contato
)
SELECT
  audios,
  ROUND(100.0 * audios / NULLIF(total, 0), 2) AS pct_audio,
  imagens,
  ROUND(100.0 * imagens / NULLIF(total, 0), 2) AS pct_imagem,
  arquivos,
  so_texto,
  total
FROM base;
```

**Resposta esperada (numeros reais validados):**
> Distribuicao das 46.447 mensagens recebidas dos contatos:
> - **Audio:** 1.753 com transcricao nativa do Chatwoot (~3.8%)
> - **Imagem:** ~4.000+ (~9%)
> - **Arquivo:** ~280
> - **So texto:** restante (~87%)
>
> Audio nao e dominante mas existe — vale lembrar que a transcricao agora vem em `attachments[0].transcribed_text` (mudou em 2026-05 — ver decisao #7).

---

### 11. "Mostra a transcricao dos audios dessa conversa"

**Pergunta natural:** "tem uma conversa chata com a Madalena, queria ler os audios"

**SQL:**
```sql
SELECT
  mc.chatwoot_message_id,
  mc.message_created_at,
  mc.sender_type,
  (mc.attachments->0->>'transcribed_text') AS transcricao
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
WHERE cc.contact_name ILIKE '%Madalena%'
  AND cc.cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Andrea%' LIMIT 1)
  AND mc.attachments @> '[{"file_type":"audio"}]'::jsonb
ORDER BY mc.message_created_at;
```

**Resposta esperada:** lista cronologica de audios com transcricao + remetente, sem precisar abrir o Chatwoot.

---

## Categoria: Comparativo / Diagnostico

### 12. "Tem cliente que esta com a taxa de resolucao caindo?"

**Pergunta natural:** "compara essa semana vs anterior: alguem teve queda na taxa de resolucao?"

**SQL:**
```sql
WITH semana AS (
  SELECT
    c.nome AS cliente,
    CASE
      WHEN cc.created_at >= (now() - interval '7 days')  THEN 'atual'
      WHEN cc.created_at >= (now() - interval '14 days') THEN 'anterior'
    END AS janela,
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE cc.status = 'resolved') AS resolvidas
  FROM conversas_chatwoot cc
  JOIN clientes c ON c.id = cc.cliente_id
  WHERE cc.created_at >= (now() - interval '14 days')
  GROUP BY c.nome, janela
)
SELECT
  cliente,
  MAX(CASE WHEN janela='anterior' THEN ROUND(100.0 * resolvidas / NULLIF(total,0), 1) END) AS pct_resolvidas_anterior,
  MAX(CASE WHEN janela='atual'    THEN ROUND(100.0 * resolvidas / NULLIF(total,0), 1) END) AS pct_resolvidas_atual,
  MAX(CASE WHEN janela='anterior' THEN total END) AS volume_anterior,
  MAX(CASE WHEN janela='atual'    THEN total END) AS volume_atual
FROM semana
GROUP BY cliente
ORDER BY cliente;
```

**Resposta esperada:** tabela cliente x % resolvidas (semana atual vs anterior). Diferencas grandes (>5 p.p.) merecem investigacao.

---

## Categoria: Raio-x operacional do cliente (gabarito Bruno)

### "Cliente X esta bem?" / "Como esta o atendimento da X?"

Pergunta vaga mas comum. Resposta deve cobrir 4 dimensoes:

**1. Backlog atual** (conversas abertas, pending, paradas ha muito tempo):

```sql
SELECT
  COUNT(*) FILTER (WHERE status = 'open') AS abertas,
  COUNT(*) FILTER (WHERE status = 'pending') AS pendentes,
  COUNT(*) FILTER (WHERE status = 'resolved') AS resolvidas,
  COUNT(*) FILTER (WHERE status = 'open' AND last_activity_at < now() - interval '7 days') AS paradas_mais_7_dias,
  COUNT(*) FILTER (WHERE status = 'open' AND last_activity_at < now() - interval '3 days') AS paradas_mais_3_dias,
  ROUND(100.0 * COUNT(*) FILTER (WHERE status='resolved') / COUNT(*), 1) AS pct_resolucao
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Bruno Lucarelli%' LIMIT 1);
```

**2. Tempo medio de primeira resposta + mediana** (mediana mais justa por causa de cauda longa):

```sql
SELECT
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tmr_min) AS mediana_min,
  ROUND(AVG(tmr_min)) AS media_min,
  COUNT(*) AS amostra
FROM (
  SELECT EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/60 AS tmr_min
  FROM conversas_chatwoot
  WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Bruno Lucarelli%' LIMIT 1)
    AND created_at >= now() - interval '30 days'
    AND first_reply_created_at > created_at
) sub;
```

**3. Volume diario** (descobrir picos ou quedas anormais):

```sql
SELECT DATE_TRUNC('day', created_at)::date AS dia, COUNT(*) AS novas
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Bruno Lucarelli%' LIMIT 1)
  AND created_at >= now() - interval '14 days'
GROUP BY dia ORDER BY dia DESC;
```

**4. Casos longos pra investigacao** (a cauda — pode ser incidente isolado):

```sql
SELECT
  chatwoot_conversation_id,
  created_at::date AS aberta_em,
  ROUND(EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/3600) AS horas_ate_resposta,
  contact_name
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Bruno Lucarelli%' LIMIT 1)
  AND first_reply_created_at > created_at
ORDER BY (first_reply_created_at - created_at) DESC
LIMIT 5;
```

**Resposta esperada (formato pro operador):**

> No geral, o **Bruno esta bem**.
>
> **Backlog saudavel:**
> - 6 conversas abertas, 0 pendentes, **99,5% resolvidas** (1.103 de 1.109).
> - Nenhuma conversa parada ha mais de 7 dias.
>
> **Tempo de resposta com cauda:**
> - Mediana de **5h32** (~bom).
> - Mas a media e **~53h** (alta) — sinal de cauda longa.
>
> **Diagnostico da cauda:** as 5 conversas mais demoradas dele abriram **todas em 13/05** e levaram ~361h (≈15 dias) pra primeira resposta. Provavelmente foi um lote que escapou da fila naquele dia, nao lentidao recorrente. A mediana confirma.
>
> Quer que eu liste tudo que abriu em 13/05 pra investigar o que aconteceu?

---

## Categoria: Labels (variam por cliente)

### "Quais labels o cliente X usa?"

Quase obrigatorio rodar essa ANTES de tentar filtrar por label especifica. Labels variam radicalmente por cliente.

```sql
SELECT
  jsonb_array_elements_text(labels) AS label,
  COUNT(*) AS qtd
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE 'Andrea%' LIMIT 1)
  AND jsonb_array_length(labels) > 0
GROUP BY label
ORDER BY qtd DESC;
```

**Exemplo de resposta esperada:**

> Andrea Vermont usa **6 labels distintas**:
>
> | Label | Conversas |
> |---|---|
> | `iadepoimentosandreavermont` | 43 |
> | `depoimentosalunosandrea` | 39 |
> | `feedbackandreavermont` | 34 |
> | `feedbackterceiriza` | 21 |
> | `erronaia` | 3 |
> | `historicoia` | 2 |
>
> **Nenhuma label de "urgente" ou similar** — as labels dela sao todas voltadas a depoimentos, feedback e marcacoes internas de IA.
>
> Se voce quer encontrar "casos urgentes" sem label, da pra ir por palavras de insatisfacao no texto ("absurdo", "procon", "cancela tudo") ou pelas conversas paradas ha mais tempo. Qual prefere?

---

## Notas importantes pro Analista (ler antes de responder)

1. **NUNCA mostre SQL nem tabelas cruas pro operador.** Traduza tudo pra linguagem natural com numeros destacados, listas e insights curtos.
2. **Quando o operador disser "esse cliente", pergunte qual** — sao 16 clientes no sistema (ver `infra/CLAUDE.md`); Andrea domina o volume, mas nao e a unica.
3. **Notas privadas (`private=true`) NAO sao internas reais** — sao **espelhos de templates HSM enviados ao cliente** (boas-vindas, reembolso). Por padrao, conte como outgoing. Ver Armadilha 1 do INSTRUCOES.md.
4. **Labels variam por cliente** — antes de filtrar `WHERE labels ? 'urgente'`, rode primeiro a query "Labels usadas por cliente X" pra descobrir o que cada um realmente usa.
5. **Defensiva contra TMR negativo:** sempre adicionar `AND first_reply_created_at > created_at` em queries de tempo de resposta.
6. **Mediana > media** quando ha cauda longa (tipico de tempo de resposta — apresente os dois e explique a diferenca quando o gap for grande).
7. **Sao Paulo timezone** para queries de hora-do-dia: `AT TIME ZONE 'America/Sao_Paulo'`.
8. **Stopwords PT-BR + nomes da persona:** em analise de palavras-chave, remova saudacoes ("oi", "ola", "bom dia", "obrigada", "tarde") e nomes dos atendentes/personas (ex: "pamela") — eles dominam o ranking sem trazer insight.
9. **Backfill historico:** dados foram sincronizados em 2026-05-28; algumas metricas de TMR no inicio do dataset podem estar enviesadas pelo sync atrasado. Ao reportar, mencionar a janela temporal.
10. **Read-only.** Nunca rode `INSERT/UPDATE/DELETE` — so consulta. Ver `CONECTOR-SUPABASE.md`.

Para o catalogo completo de queries reutilizaveis, veja `QUERIES-SQL.md`.
