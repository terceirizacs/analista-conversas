# Biblioteca de Queries SQL — Analista de Conversas

Catalogo de queries reutilizaveis para o conector Supabase (read-only). Todas validadas contra o banco em 2026-05-28 (18.643 conversas, 130.725 mensagens, 9 clientes ativos).

**Schema:** `conversas_chatwoot` e `mensagens_chatwoot` (ver `infra/supabase/schema-canonico.sql` na raiz do projeto).

**Como usar este arquivo:**
- Para consultas livres do operador, ver `EXEMPLOS-DE-PERGUNTAS.md` (mais didatico).
- Este arquivo e referencia tecnica — queries direto ao ponto + output esperado.

**Defaults importantes:**
- Use `cliente_id` para escopar — quase nunca o operador quer cross-client.
- `message_type`: 0=incoming (contato), 1=outgoing (agente/bot), 2=activity, 3=template.
- `sender_type` (LOWERCASE pos-normalizacao no handler): `contact` / `user` / `agent_bot` / NULL (activity).
- Timezone do dataset: UTC no banco. Para hora-do-dia BRT, usar `AT TIME ZONE 'America/Sao_Paulo'`.
- Conversas com `first_reply_created_at <= created_at` (~50% do dataset) sao quirks — filtrar `> created_at` para metricas de tempo.

---

## Q01. Resumo do banco

**Descricao:** retorna 3 numeros principais — total de clientes, conversas e mensagens. Usar como check inicial.

```sql
SELECT
  (SELECT COUNT(*) FROM clientes) AS clientes,
  (SELECT COUNT(*) FROM conversas_chatwoot) AS conversas,
  (SELECT COUNT(*) FROM mensagens_chatwoot) AS mensagens;
```

**Output esperado (2026-05-28):**
```
clientes | conversas | mensagens
       9 |    18.643 |   130.725
```

---

## Q02. Volume de conversas por cliente

**Descricao:** ranking dos clientes por volume sincronizado.

```sql
SELECT
  c.nome AS cliente,
  COUNT(cc.id) AS conversas,
  ROUND(100.0 * COUNT(cc.id) / NULLIF(SUM(COUNT(cc.id)) OVER (), 0), 1) AS pct
FROM clientes c
LEFT JOIN conversas_chatwoot cc ON cc.cliente_id = c.id
GROUP BY c.nome
ORDER BY conversas DESC;
```

**Output esperado (validado):**
```
Andrea Vermont    10.142  54.4%
Rafa Bueno         1.944  10.4%
Lucas Arrial       1.719   9.2%
Murilo Arjona      1.719   9.2%
Breno Koscky       1.463   7.8%
Bruno Lucarelli    1.109   6.0%
Projeto IA           377   2.0%
Elisa Fingermann     121   0.6%
Tia Do Ingles         49   0.3%
```

---

## Q03. Conversas novas por dia (ultimos 14 dias)

**Descricao:** serie temporal de novas conversas. Filtravel por cliente.

```sql
SELECT
  DATE_TRUNC('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
  COUNT(*) AS novas_conversas
FROM conversas_chatwoot
WHERE created_at >= (now() - interval '14 days')
  -- AND cliente_id = '<UUID>'   <- descomentar para filtrar por cliente
GROUP BY dia
ORDER BY dia DESC;
```

**Output esperado (Andrea, semana 22-28 mai 2026):**
- Dias uteis: 400-535 conversas
- Sabado/domingo: 55-66 conversas (~12% de dia util)
- 25 maio (segunda): pico de 535

---

## Q04. Status atual (open / pending / resolved / snoozed) por cliente

**Descricao:** backlog real — quantas conversas estao aguardando humano.

```sql
SELECT
  c.nome AS cliente,
  COUNT(*) FILTER (WHERE cc.status = 'open')     AS abertas,
  COUNT(*) FILTER (WHERE cc.status = 'pending')  AS pendentes,
  COUNT(*) FILTER (WHERE cc.status = 'snoozed')  AS snoozed,
  COUNT(*) FILTER (WHERE cc.status = 'resolved') AS resolvidas,
  ROUND(100.0 * COUNT(*) FILTER (WHERE cc.status = 'resolved') / NULLIF(COUNT(*), 0), 1) AS pct_resolvidas
FROM clientes c
JOIN conversas_chatwoot cc ON cc.cliente_id = c.id
GROUP BY c.nome
ORDER BY abertas DESC;
```

**Output esperado (top do dataset):**
```
Andrea Vermont: 79 abertas / 0 pendentes / 10.063 resolvidas (99.2%)
```

---

## Q05. Conversas mais antigas em aberto (backlog stale)

**Descricao:** lista das conversas paradas ha mais tempo, para acionamento manual.

```sql
SELECT
  c.nome AS cliente,
  cc.chatwoot_conversation_id,
  cc.contact_name,
  cc.contact_phone,
  cc.last_activity_at,
  age(now(), cc.last_activity_at) AS aguardando_ha,
  cc.ultima_mensagem_preview
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
WHERE cc.status IN ('open', 'pending')
  AND cc.last_activity_at < (now() - interval '3 days')
ORDER BY cc.last_activity_at ASC
LIMIT 30;
```

**Output esperado:** as 30 conversas mais paradas, com indicacao do contato e preview da ultima mensagem.

---

## Q06. Tempo medio e mediano de resposta (TMR)

**Descricao:** metrica de SLA do primeiro reply, com filtro defensivo.

```sql
SELECT
  c.nome AS cliente,
  ROUND(AVG(EXTRACT(EPOCH FROM (cc.first_reply_created_at - cc.created_at)) / 60)::numeric, 0) AS tmr_min_media,
  ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (cc.first_reply_created_at - cc.created_at)) / 60)::numeric, 0) AS tmr_min_mediana,
  COUNT(*) AS amostra
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
WHERE cc.first_reply_created_at IS NOT NULL
  AND cc.first_reply_created_at > cc.created_at  -- defensivo contra quirks
  AND cc.created_at >= (now() - interval '30 days')
GROUP BY c.nome
ORDER BY tmr_min_media DESC;
```

**Output esperado:** TMR em minutos por cliente. Andrea historicamente fica em ~1.462 min (~24h) — atendimento humano, nao bot.

**Observacao:** se o operador quiser TMR de uma conversa especifica, basta WHERE chatwoot_conversation_id = X.

---

## Q07. Distribuicao por hora do dia (BRT)

**Descricao:** picos de demanda — usar pra dimensionamento de plantao.

```sql
SELECT
  EXTRACT(HOUR FROM message_created_at AT TIME ZONE 'America/Sao_Paulo')::int AS hora_brt,
  COUNT(*) AS mensagens_de_contatos
FROM mensagens_chatwoot
WHERE message_type = 0
  AND message_created_at >= (now() - interval '30 days')
GROUP BY hora_brt
ORDER BY hora_brt;
```

**Output esperado:** 24 linhas (0-23h). Esperar pico noturno (19-22h) em CS B2C.

---

## Q08. Top palavras-chave em mensagens de contato

**Descricao:** lista das palavras mais usadas pelos clientes (incoming). Stopwords PT-BR removidas.

```sql
WITH palavras AS (
  SELECT lower(regexp_replace(unnest(regexp_split_to_array(content, '\s+')), '[^a-zà-úçâêôãõ]', '', 'g')) AS palavra
  FROM mensagens_chatwoot
  WHERE message_type = 0
    AND content IS NOT NULL
    AND message_created_at >= (now() - interval '30 days')
)
SELECT palavra, COUNT(*) AS freq
FROM palavras
WHERE LENGTH(palavra) > 4
  AND palavra NOT IN (
    'para','muito','quando','porque','sobre','agora','tudo','obrigada','obrigado',
    'também','estou','estamos','consigo','poderia','queria','gostaria','minha','tenho',
    'tinha','fazer','dizer','vocês','desde','algum','algumas','depois','antes','ainda',
    'então','assim','mesmo','outro','outra','sempre','nunca','hoje','ontem','amanhã'
  )
GROUP BY palavra
ORDER BY freq DESC
LIMIT 30;
```

**Output esperado (validado, ultimos 30 dias do banco):**
- "curso" (1.042), "pamela" (645 — nome da persona da Andrea), "acessar"/"acesso" (746 somados), "plataforma" (278), "aulas" (391)
- Tema dominante claro: **acesso a plataforma educacional**.

---

## Q09. Buckets tematicos (regex curado)

**Descricao:** divide mensagens de contato em buckets por palavra-chave. Util pra dashboard.

```sql
SELECT
  COUNT(*) FILTER (WHERE content ILIKE '%reembolso%' OR content ILIKE '%devolu%') AS reembolso,
  COUNT(*) FILTER (WHERE content ILIKE '%prazo%' OR content ILIKE '%demor%' OR content ILIKE '%atras%') AS prazo,
  COUNT(*) FILTER (WHERE content ILIKE '%cancela%') AS cancelar,
  COUNT(*) FILTER (WHERE content ILIKE '%acesso%' OR content ILIKE '%senha%' OR content ILIKE '%login%' OR content ILIKE '%entrar%') AS acesso,
  COUNT(*) FILTER (WHERE content ILIKE '%boleto%' OR content ILIKE '%paga%' OR content ILIKE '%pix%') AS pagamento,
  COUNT(*) FILTER (WHERE content ILIKE '%certificad%' OR content ILIKE '%diploma%') AS certificado,
  COUNT(*) AS total_msgs_de_contato
FROM mensagens_chatwoot
WHERE message_type = 0
  AND content IS NOT NULL;
```

**Output esperado (historico completo):**
```
acesso        1.136
pagamento       604
prazo           441
cancelar        429
reembolso       136
certificado     (a medir)
total         46.447 msgs de contato
```

---

## Q10. Conversas mais longas

**Descricao:** top 20 conversas por numero de mensagens. Casos "dificeis" merecem revisao da base de conhecimento.

```sql
SELECT
  c.nome AS cliente,
  cc.chatwoot_conversation_id,
  cc.contact_name,
  cc.status,
  cc.created_at::date AS abriu_em,
  COUNT(mc.id) AS qtd_mensagens,
  cc.ultima_mensagem_preview
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
JOIN mensagens_chatwoot mc ON mc.conversa_id = cc.id
GROUP BY c.nome, cc.id, cc.chatwoot_conversation_id, cc.contact_name, cc.status, cc.created_at, cc.ultima_mensagem_preview
ORDER BY qtd_mensagens DESC
LIMIT 20;
```

**Output esperado (top 5 reais):**
```
Andrea | 11971 | Sueli Lopes        | resolved | 209 msgs
Andrea |  4563 | Madalena           | resolved | 190 msgs
Andrea |  4146 | Flavia             | resolved | 179 msgs
Andrea |  1241 | Willian            | resolved | 161 msgs
Andrea |   916 | Kátia Thomazine    | resolved | 157 msgs
```

---

## Q11. Distribuicao por tipo de attachment

**Descricao:** quantas mensagens tem audio/imagem/arquivo. Usa operador `@>` do JSONB.

```sql
SELECT
  COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"audio"}]'::jsonb)    AS audios,
  COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"image"}]'::jsonb)    AS imagens,
  COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"file"}]'::jsonb)     AS arquivos,
  COUNT(*) FILTER (WHERE attachments @> '[{"file_type":"video"}]'::jsonb)    AS videos,
  COUNT(*) FILTER (WHERE attachments = '[]'::jsonb OR attachments IS NULL)   AS so_texto,
  COUNT(*) AS total
FROM mensagens_chatwoot
WHERE message_type = 0;
```

**Output esperado:** distribuicao por tipo de attachment. ~3.8% audio, ~9% imagem, restante texto.

---

## Q12. Transcricao de audios de uma conversa

**Descricao:** extrai `attachments[0].transcribed_text` para audios. Util pra ler o conteudo sem abrir o Chatwoot.

```sql
SELECT
  mc.chatwoot_message_id,
  mc.message_created_at,
  mc.sender_type,
  (mc.attachments->0->>'transcribed_text') AS transcricao
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
WHERE cc.chatwoot_conversation_id = :id_da_conversa
  AND mc.attachments @> '[{"file_type":"audio"}]'::jsonb
ORDER BY mc.message_created_at;
```

**Nota tecnica:** o Chatwoot mudou o local da transcricao em 2026-05 — agora vem em `attachments[0].transcribed_text` (antes em `content_attributes.transcribed_text`). Decisao #7 do projeto.

---

## Q13. Taxa de handoff (nota privada vs publica)

**Descricao:** quantas vezes o bot fez handoff para humano. Notas privadas (`private = true`) sao tipicamente o resumo do bot antes do handoff.

```sql
SELECT
  c.nome AS cliente,
  COUNT(*) FILTER (WHERE mc.private = true) AS notas_privadas,
  COUNT(*) FILTER (WHERE mc.message_type = 1 AND mc.private = false) AS mensagens_publicas,
  ROUND(100.0 * COUNT(*) FILTER (WHERE mc.private = true) / NULLIF(COUNT(*) FILTER (WHERE mc.message_type = 1), 0), 2) AS pct_handoff
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
JOIN clientes c ON c.id = cc.cliente_id
WHERE mc.message_created_at >= (now() - interval '30 days')
GROUP BY c.nome
ORDER BY pct_handoff DESC NULLS LAST;
```

**Output esperado:** % de notas privadas / mensagens outgoing por cliente. Sinal de saude do bot.

---

## Q14. Conversas com sentimento "negativo" (heuristica)

**Descricao:** o campo `sentiment` JSONB do Chatwoot e raramente populado, entao a query usa heuristica de palavras-chave de frustracao.

```sql
SELECT
  c.nome AS cliente,
  cc.chatwoot_conversation_id,
  cc.contact_name,
  cc.status,
  cc.last_activity_at::date AS ultima_atividade,
  COUNT(mc.id) AS marcas_negativas,
  STRING_AGG(DISTINCT LEFT(mc.content, 80), ' | ' ORDER BY LEFT(mc.content, 80)) AS amostras
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
JOIN clientes c ON c.id = cc.cliente_id
WHERE mc.message_type = 0
  AND (
    mc.content ILIKE '%absurdo%' OR
    mc.content ILIKE '%péssimo%' OR mc.content ILIKE '%pessimo%' OR
    mc.content ILIKE '%horrível%' OR mc.content ILIKE '%horrivel%' OR
    mc.content ILIKE '%procon%' OR
    mc.content ILIKE '%processar%' OR
    mc.content ILIKE '%golpe%' OR mc.content ILIKE '%enganaram%' OR
    mc.content ILIKE '%cancela tudo%' OR
    mc.content ILIKE '%nunca mais%'
  )
  AND mc.message_created_at >= (now() - interval '30 days')
GROUP BY c.nome, cc.chatwoot_conversation_id, cc.contact_name, cc.status, cc.last_activity_at
ORDER BY marcas_negativas DESC
LIMIT 15;
```

**Output esperado:** conversas com sinais claros de insatisfacao + amostras de texto. Triagem prioritaria.

---

## Q15. Distribuicao por tipo de mensagem e remetente

**Descricao:** sanity check — quem mais fala (cliente vs agente vs bot vs sistema).

```sql
SELECT
  message_type,
  COALESCE(sender_type, '(activity/sistema)') AS sender_type,
  COUNT(*) AS qtd,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM mensagens_chatwoot
GROUP BY message_type, sender_type
ORDER BY qtd DESC;
```

**Output esperado (validado):**
```
1 user        56.735 (43.4%)   <- agente humano
0 contact     46.447 (35.5%)   <- cliente
2 NULL        26.813 (20.5%)   <- eventos sistema
3 NULL           690  (0.5%)   <- templates WhatsApp
1 agent_bot       40 (0.03%)   <- bot CS-IA
```

**Observacao:** `agent_bot` so 40 msgs no dataset total — sinal de que o bot CS-IA ainda esta em fase inicial / poucos clientes ativos.

---

## Q16. Mensagens por conversa (distribuicao)

**Descricao:** histograma de qtd de mensagens por conversa. Util pra entender "conversa tipica".

```sql
WITH conv_size AS (
  SELECT cc.id, COUNT(mc.id) AS msgs
  FROM conversas_chatwoot cc
  LEFT JOIN mensagens_chatwoot mc ON mc.conversa_id = cc.id
  GROUP BY cc.id
)
SELECT
  CASE
    WHEN msgs = 0 THEN '0'
    WHEN msgs BETWEEN 1 AND 5 THEN '1-5'
    WHEN msgs BETWEEN 6 AND 15 THEN '6-15'
    WHEN msgs BETWEEN 16 AND 30 THEN '16-30'
    WHEN msgs BETWEEN 31 AND 60 THEN '31-60'
    WHEN msgs BETWEEN 61 AND 100 THEN '61-100'
    ELSE '100+'
  END AS faixa_msgs,
  COUNT(*) AS qtd_conversas
FROM conv_size
GROUP BY faixa_msgs
ORDER BY MIN(msgs);
```

**Output esperado:** distribuicao de tamanho de conversa. Maioria fica em 1-15 msgs; cauda longa de 100+ sao casos dificeis.

---

## Q17. Frequencia de contato unico (clientes recorrentes)

**Descricao:** clientes que voltam a abrir conversa varias vezes — pode indicar problema cronico ou cliente engajado.

```sql
SELECT
  c.nome AS cliente,
  cc.contact_phone,
  cc.contact_name,
  COUNT(DISTINCT cc.id) AS qtd_conversas,
  MIN(cc.created_at)::date AS primeira_conversa,
  MAX(cc.last_activity_at)::date AS ultima_atividade
FROM conversas_chatwoot cc
JOIN clientes c ON c.id = cc.cliente_id
WHERE cc.contact_phone IS NOT NULL
GROUP BY c.nome, cc.contact_phone, cc.contact_name
HAVING COUNT(DISTINCT cc.id) >= 5
ORDER BY qtd_conversas DESC
LIMIT 20;
```

**Output esperado:** contatos com 5+ conversas. Bons candidatos para entrevista qualitativa ou analise de churn.

---

## Q18. Conversas que receberam template WhatsApp (message_type=3)

**Descricao:** templates HSM sao mensagens proativas (re-engajamento). Mede iniciativas outbound.

```sql
SELECT
  c.nome AS cliente,
  COUNT(DISTINCT mc.conversa_id) AS conversas_com_template,
  COUNT(*) AS templates_enviados,
  ROUND(AVG(LENGTH(mc.content))::numeric, 0) AS tamanho_medio_template
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
JOIN clientes c ON c.id = cc.cliente_id
WHERE mc.message_type = 3
GROUP BY c.nome
ORDER BY templates_enviados DESC;
```

**Output esperado:** quantos templates cada cliente disparou. Total dataset: 690 templates.

---

## Q19. Heatmap dia-da-semana x hora

**Descricao:** matriz pra visualizacao (operador pode pedir grafico, ai exportar pra CSV).

```sql
SELECT
  TO_CHAR(message_created_at AT TIME ZONE 'America/Sao_Paulo', 'Day') AS dia_semana,
  EXTRACT(HOUR FROM message_created_at AT TIME ZONE 'America/Sao_Paulo')::int AS hora_brt,
  COUNT(*) AS msgs
FROM mensagens_chatwoot
WHERE message_type = 0
  AND message_created_at >= (now() - interval '30 days')
GROUP BY dia_semana, hora_brt
ORDER BY MIN(EXTRACT(DOW FROM message_created_at AT TIME ZONE 'America/Sao_Paulo')), hora_brt;
```

**Output esperado:** grid 7 dias x 24 horas. Picos esperados: ter-qui 19h-22h.

---

## Q20. Detalhe de uma conversa especifica (debug)

**Descricao:** retorna a conversa completa em ordem cronologica — util quando o operador quer "ler tudo".

```sql
SELECT
  mc.message_created_at,
  mc.sender_type,
  mc.sender_name,
  mc.message_type,
  mc.private,
  CASE
    WHEN mc.attachments != '[]'::jsonb THEN
      COALESCE(mc.content, '') || ' [' || (mc.attachments->0->>'file_type') || ']' ||
      COALESCE(' transcricao: ' || (mc.attachments->0->>'transcribed_text'), '')
    ELSE mc.content
  END AS linha
FROM mensagens_chatwoot mc
JOIN conversas_chatwoot cc ON cc.id = mc.conversa_id
WHERE cc.chatwoot_conversation_id = :id_da_conversa
  -- AND cc.cliente_id = '<UUID do cliente>'  <- escopar se necessario
ORDER BY mc.message_created_at;
```

**Output esperado:** uma linha por mensagem, cronologica, indicando sender, tipo, privacidade e conteudo (incluindo attachment + transcricao se houver).

---

## Apendice — Convencoes e gotchas

1. **`cliente_id` e UUID, nao integer.** Sempre buscar pelo nome com `WHERE nome ILIKE 'X%'` em subquery.
2. **Datas chegam em UTC.** Para output ao usuario, converter pra `America/Sao_Paulo`.
3. **`raw_payload` JSONB existe** em ambas as tabelas para fallback. Evitar em queries normais (perf alta), usar so em debug.
4. **JSONB operadores uteis:**
   - `attachments @> '[{"file_type":"audio"}]'::jsonb` — testa se array tem objeto com chave/valor.
   - `attachments->0->>'transcribed_text'` — pega o campo `transcribed_text` do primeiro elemento como text.
   - `jsonb_array_length(attachments)` — quantidade de attachments.
5. **TMR (tempo de resposta):** sempre `AND first_reply_created_at > created_at` — 50% do dataset tem igualdade (caso onde a primeira reply == criacao da conversa).
6. **Status `resolved` domina** (99%). Para metrica de "abertas hoje", filtrar `status IN ('open','pending')`.
7. **Read-only.** Nunca rodar `INSERT/UPDATE/DELETE/ALTER`. Conector deve estar com `read_only=true` (ver CONECTOR-SUPABASE.md).

---

## Q21. Labels efetivamente em uso por cliente

**Descricao:** descobre o vocabulario de labels que o cliente realmente usa. **Rode ANTES de tentar filtrar por uma label especifica** — labels variam radicalmente entre clientes (Andrea tem `iadepoimentosandreavermont` mas nao tem `urgente`).

```sql
SELECT
  jsonb_array_elements_text(labels) AS label,
  COUNT(*) AS qtd_conversas
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1)
  AND jsonb_array_length(labels) > 0
GROUP BY label
ORDER BY qtd_conversas DESC;
```

**Output esperado:** lista de labels com contagem. Se vazio, o cliente nao usa labels.

---

## Q22. Outgoing REAL (publicas + notas privadas espelho + templates)

**Descricao:** total de mensagens que efetivamente chegaram ao cliente. Inclui notas privadas (sao espelhos de templates HSM enviados, ver Armadilha 1 do INSTRUCOES.md). **Use esta query, NAO o `message_type=1 AND private=false` simples**.

```sql
SELECT
  COUNT(*) FILTER (WHERE message_type = 0)                                    AS recebidas_cliente,
  COUNT(*) FILTER (WHERE message_type = 1 AND private = false)                AS enviadas_publicas,
  COUNT(*) FILTER (WHERE message_type = 1 AND private = true)                 AS enviadas_via_template_espelho,
  COUNT(*) FILTER (WHERE message_type = 3)                                    AS templates_diretos,
  COUNT(*) FILTER (WHERE message_type = 1 OR message_type = 3)                AS total_outgoing_real,
  ROUND(
    COUNT(*) FILTER (WHERE message_type = 0)::numeric /
    NULLIF(COUNT(*) FILTER (WHERE message_type = 1 OR message_type = 3), 0),
    2
  ) AS razao_recebidas_por_enviada
FROM mensagens_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1)
  AND message_created_at >= now() - interval '7 days';
```

**Como apresentar:** "O cliente recebeu **X mensagens** do contato e respondeu com **Y mensagens** (Y1 publicas + Y2 templates espelhados + Y3 templates diretos). Razao: cada mensagem do cliente teve ~Z resposta(s)."

---

## Q23. Raio-x operacional do cliente (saude do atendimento)

**Descricao:** resposta canonica pra perguntas do tipo "Cliente X esta bem?" ou "Como esta o atendimento da X?". Cobre 4 dimensoes em uma chamada — backlog, TMR, volume, casos longos.

**Parte A — Backlog:**

```sql
SELECT
  COUNT(*) AS total_conversas,
  COUNT(*) FILTER (WHERE status = 'open') AS abertas,
  COUNT(*) FILTER (WHERE status = 'pending') AS pendentes,
  COUNT(*) FILTER (WHERE status = 'resolved') AS resolvidas,
  COUNT(*) FILTER (WHERE status = 'open' AND last_activity_at < now() - interval '3 days') AS paradas_mais_3_dias,
  COUNT(*) FILTER (WHERE status = 'open' AND last_activity_at < now() - interval '7 days') AS paradas_mais_7_dias,
  ROUND(100.0 * COUNT(*) FILTER (WHERE status='resolved') / NULLIF(COUNT(*),0), 1) AS pct_resolucao
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1);
```

**Parte B — TMR (mediana e media):**

```sql
SELECT
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tmr_min)) AS mediana_min,
  ROUND(AVG(tmr_min)) AS media_min,
  COUNT(*) AS amostra
FROM (
  SELECT EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/60 AS tmr_min
  FROM conversas_chatwoot
  WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1)
    AND created_at >= now() - interval '30 days'
    AND first_reply_created_at > created_at
) sub;
```

**Parte C — Volume diario ultimas 2 semanas:**

```sql
SELECT DATE_TRUNC('day', created_at)::date AS dia, COUNT(*) AS novas
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1)
  AND created_at >= now() - interval '14 days'
GROUP BY dia ORDER BY dia DESC;
```

**Parte D — Top 5 casos mais demorados (investigar incidente isolado):**

```sql
SELECT
  chatwoot_conversation_id,
  created_at::date AS aberta_em,
  ROUND(EXTRACT(EPOCH FROM (first_reply_created_at - created_at))/3600) AS horas_ate_primeira_resposta,
  contact_name,
  status
FROM conversas_chatwoot
WHERE cliente_id = (SELECT id FROM clientes WHERE nome ILIKE '${nome_cliente}%' LIMIT 1)
  AND first_reply_created_at > created_at
ORDER BY (first_reply_created_at - created_at) DESC
LIMIT 5;
```

**Quando rodar:** sempre que o operador perguntar "como esta o X?" / "o X esta bem?" / "tudo certo com Y?". Ver gabarito completo de resposta em `EXEMPLOS-DE-PERGUNTAS.md` (categoria "Raio-x operacional do cliente").

---

**Manutencao:** ao mudar schema (nova migration), revalidar todas as queries deste arquivo via MCP supabase antes de promover ao banco. Source-of-truth do schema: `infra/supabase/schema-canonico.sql`.
