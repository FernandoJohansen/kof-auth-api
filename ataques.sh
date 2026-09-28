#!/usr/bin/env bash
# Suíte de ataques contra a kof-auth-api. Cada teste imprime PASS ou FAIL.
# Uso: BASE=http://localhost:8080 ADMIN_PASSWORD='...' ./ataques.sh
# Requer: curl, openssl, base64.
# Obs.: roda contra um servidor recém-iniciado (o rate limit guarda estado).

BASE="${BASE:-http://localhost:8080}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?defina ADMIN_PASSWORD igual ao do servidor}"
PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
nok()  { echo "  FAIL  $1 (obtido: $2)"; FAIL=$((FAIL+1)); }
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
espera() { local nome=$1 esperado=$2; shift 2; local c; c=$(code "$@"); [ "$c" = "$esperado" ] && ok "$nome → $c" || nok "$nome (esperado $esperado)" "$c"; }
json() { printf '{"username":"%s","password":"%s"}' "$1" "$2"; }
post() { curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }
b64url() { base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
token_de() { sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }

echo "== Superfície e headers"
H=$(curl -s -i "$BASE/health")
echo "$H" | grep -qi '^X-Content-Type-Options: nosniff' && ok "X-Content-Type-Options presente" || nok "X-Content-Type-Options" "ausente"
echo "$H" | grep -qi '^X-Frame-Options: DENY' && ok "X-Frame-Options presente" || nok "X-Frame-Options" "ausente"
echo "$H" | grep -qi '^Content-Security-Policy:' && ok "Content-Security-Policy presente" || nok "CSP" "ausente"
espera "rota desconhecida exige auth" 401 "$BASE/qualquer-coisa"

echo "== Registro e validação de entrada"
espera "JSON malformado" 400 -X POST "$BASE/register" -d '{lixo'
espera "campo faltando (password)" 400 -X POST "$BASE/register" -d '{"username":"ana"}'
espera "senha curta" 400 -X POST "$BASE/register" -d "$(json ana curta123)"
espera "senha comum" 400 -X POST "$BASE/register" -d "$(json ana password1234)"
espera "senha contém o username" 400 -X POST "$BASE/register" -d "$(json ana 'minhaana-e-legal')"
espera "username com aspas (injeção JSON)" 400 -X POST "$BASE/register" -d '{"username":"a\"b","password":"Cavalo-Bateria-Grampo-9"}'
espera "username com quebra de linha (log injection)" 400 -X POST "$BASE/register" -d '{"username":"ana\nFAKE LOG","password":"Cavalo-Bateria-Grampo-9"}'
espera "registro válido" 201 -X POST "$BASE/register" -d "$(json ana 'Cavalo-Bateria-Grampo-9')"
espera "registro duplicado" 409 -X POST "$BASE/register" -d "$(json ana 'Cavalo-Bateria-Grampo-9')"
espera "duplicado com maiúsculas (normalização)" 409 -X POST "$BASE/register" -d "$(json ANA 'Cavalo-Bateria-Grampo-9')"
GRANDE=$(head -c 6000 /dev/zero | tr '\0' 'a')
espera "corpo acima do limite" 413 -X POST "$BASE/register" -d "{\"username\":\"$GRANDE\"}"

echo "== Login e anti-enumeração"
R1=$(post /login "$(json ana 'senha-errada-123')")
R2=$(post /login "$(json naoexiste 'senha-errada-123')")
[ "$R1" = "$R2" ] && ok "senha errada e usuário inexistente dão a MESMA resposta" || nok "respostas diferentes" "$R1 vs $R2"
T1=$(curl -s -o /dev/null -w "%{time_total}" -X POST "$BASE/login" -d "$(json ana 'senha-errada-456')")
T2=$(curl -s -o /dev/null -w "%{time_total}" -X POST "$BASE/login" -d "$(json naoexiste2 'senha-errada-456')")
echo "        tempo senha errada: ${T1}s | usuário inexistente: ${T2}s (devem ser parecidos)"
TOK=$(post /login "$(json ana 'Cavalo-Bateria-Grampo-9')" | token_de)
[ -n "$TOK" ] && ok "login válido devolve token" || nok "login válido" "sem token"

echo "== Token"
espera "/me sem token" 401 "$BASE/me"
espera "/me com token válido" 200 "$BASE/me" -H "Authorization: Bearer $TOK"
HDR=$(echo "$TOK" | cut -d. -f1); PAY=$(echo "$TOK" | cut -d. -f2); SIG=$(echo "$TOK" | cut -d. -f3)
PAY_ADMIN=$(printf '{"sub":"ana","roles":["admin"],"iss":"kof-auth","aud":"kof-api","jti":"x","exp":9999999999}' | b64url)
espera "payload adulterado (virar admin)" 401 "$BASE/admin/users" -H "Authorization: Bearer $HDR.$PAY_ADMIN.$SIG"
NONE=$(printf '{"alg":"none","typ":"JWT"}' | b64url)
espera "alg:none sem assinatura" 401 "$BASE/admin/users" -H "Authorization: Bearer $NONE.$PAY_ADMIN."
FAKE_SIG=$(printf '%s' "$HDR.$PAY_ADMIN" | openssl dgst -sha256 -hmac "segredo-chutado" -binary | b64url)
espera "assinado com segredo chutado" 401 "$BASE/admin/users" -H "Authorization: Bearer $HDR.$PAY_ADMIN.$FAKE_SIG"
espera "token lixo" 401 "$BASE/me" -H "Authorization: Bearer abc.def.ghi"

echo "== Truques de caminho (allow-list exata)"
espera "/login/ com barra final (GET)" 401 "$BASE/login/"
espera "/health/../me" 401 --path-as-is "$BASE/health/../me"
espera "/healthcheck (prefixo de rota pública)" 401 "$BASE/healthcheck"
espera "GET /login (método errado)" 401 "$BASE/login"

echo "== Autorização (RBAC)"
espera "usuário comum em /admin/users" 403 "$BASE/admin/users" -H "Authorization: Bearer $TOK"
ADM=$(post /login "$(json admin "$ADMIN_PASSWORD")" | token_de)
espera "admin em /admin/users" 200 "$BASE/admin/users" -H "Authorization: Bearer $ADM"

echo "== Logout e revogação"
espera "logout" 200 -X POST "$BASE/logout" -H "Authorization: Bearer $TOK"
espera "reuso do token após logout" 401 "$BASE/me" -H "Authorization: Bearer $TOK"

echo "== Força bruta"
post /register "$(json vitima 'Outra-Senha-Bem-Longa-7')" > /dev/null
for i in 1 2 3 4 5; do post /login "$(json vitima "chute-$i-xxxxxx")" > /dev/null; done
espera "6ª tentativa na mesma conta é bloqueada" 429 -X POST "$BASE/login" -d "$(json vitima 'Outra-Senha-Bem-Longa-7')"

echo
echo "Resultado: $PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]