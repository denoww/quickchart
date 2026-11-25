#!/usr/bin/env bash
# Teste local do guard + isolamento do QuickChart, usando o docker-compose.yml REAL do repo.
# Uso: tests/guard_test.sh        (precisa de docker + compose v2 e da porta 3008 livre)
set -uo pipefail
cd "$(dirname "$0")/.."
P=qcguardtest
B=http://127.0.0.1:3008
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
enc()  { python3 -c 'import sys,urllib.parse;print(urllib.parse.urlencode(dict(a.split("=",1) for a in sys.argv[1:])))' "$@"; }

trap 'docker compose -p $P down -v >/dev/null 2>&1' EXIT
docker compose -p $P up -d --quiet-pull >/dev/null 2>&1 || { echo "compose up falhou"; exit 1; }
for i in $(seq 1 60); do [ "$(code $B/healthcheck)" = 200 ] && break; sleep 1; done

echo "== caminho legítimo (igual ao ERP: config.to_json + URI.encode_www_form)"
CFG='{"type":"bar","data":{"labels":["Jan","Fev"],"datasets":[{"label":"Receitas e despesas","data":[1,2]}]},"options":{"locale":"pt-BR","plugins":{"title":{"display":true,"text":"Título com espaço"}}}}'
QS=$(enc "c=$CFG" w=700 h=350 bkg=white v=3)
[ "$(code $B/healthcheck)" = 200 ] && ok "healthcheck 200" || bad "healthcheck"
curl -s -o /tmp/qc_guard.png -w '%{http_code} %{content_type}\n' "$B/chart?$QS" | grep -q '^200 image/png' && ok "GET /chart do ERP → 200 PNG" || bad "GET /chart do ERP"
# Byte a byte igual ao QuickChart direto (sem guard), com a MESMA query string.
docker compose -p $P exec -T guard node -e '
  require("http").get({host:"quickchart",port:3008,path:"/chart?"+process.argv[1]},r=>{const c=[];r.on("data",d=>c.push(d));r.on("end",()=>process.stdout.write(Buffer.concat(c)))})' "$QS" > /tmp/qc_direto.png
cmp -s /tmp/qc_guard.png /tmp/qc_direto.png && ok "PNG idêntico ao do QuickChart direto ($(stat -c%s /tmp/qc_guard.png) bytes)" || bad "PNG difere do direto"
[ "$(code -H 'content-type: application/json' -d "{\"c\":$CFG,\"w\":300,\"h\":200}" $B/chart)" = 200 ] && ok "POST JSON com c objeto → 200" || bad "POST objeto"

echo "== ataques (todos têm de ser recusados ANTES de chegar ao QuickChart)"
FN='{type:"bar",data:{datasets:[{data:[1]}]},options:{x:(function(){return require("child_process").execSync("id").toString()})()}}'
[ "$(code "$B/chart?$(enc "c=$FN")")" = 400 ] && ok "GET c com função/JS → 400" || bad "GET c com função"
[ "$(code "$B/chart?$(enc 'c=(()=>{throw 1})()')")" = 400 ] && ok "GET c expressão JS → 400" || bad "GET c expressão"
[ "$(code -H 'content-type: application/json' -d "{\"c\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FN")}" $B/chart)" = 400 ] && ok "POST c string com JS → 400" || bad "POST c string JS"
[ "$(code "$B/chart?$(enc "c=$(printf %s "$FN" | base64 -w0)" encoding=base64)")" = 400 ] && ok "encoding=base64 → 400" || bad "base64"
[ "$(code "$B/chart?$(enc "c=$CFG" f=svg)")" = 400 ] && ok "format svg → 400" || bad "svg"
[ "$(code "$B/chart?$(enc "c=$CFG" x=1)")" = 400 ] && ok "parâmetro desconhecido → 400" || bad "param desconhecido"
[ "$(code "$B/chart?$(enc "c=$CFG" w=99999)")" = 400 ] && ok "w gigante → 400" || bad "w gigante"
[ "$(code "$B/gchart?cht=gv&chl=graph{a--b}")" = 404 ] && ok "/gchart (graphviz) → 404" || bad "/gchart"
[ "$(code "$B/qr?text=x")" = 404 ] && ok "/qr → 404" || bad "/qr"
[ "$(code -X POST -d chartCount=1 $B/telemetry)" = 404 ] && ok "/telemetry → 404" || bad "/telemetry"
[ "$(code -H 'content-type: application/x-www-form-urlencoded' --data-urlencode "c=$FN" $B/chart)" = 415 ] && ok "POST form-urlencoded → 415" || bad "POST form"
{ printf '{"c":{"a":"'; head -c 200000 /dev/zero | tr '\0' a; printf '"}}'; } > /tmp/qc_big.json
[ "$(code -H 'content-type: application/json' --data-binary @/tmp/qc_big.json $B/chart)" = 413 ] && ok "corpo > 128 KB → 413" || bad "corpo grande"

echo "== isolamento do container quickchart (rede internal)"
docker compose -p $P exec -T quickchart sh -c 'wget -q -T 3 -O- http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1' && bad "quickchart ALCANÇA o IMDS" || ok "quickchart não alcança o IMDS"
docker compose -p $P exec -T quickchart sh -c 'wget -q -T 3 -O- http://1.1.1.1/ >/dev/null 2>&1' && bad "quickchart ALCANÇA a internet" || ok "quickchart não alcança a internet"
docker compose -p $P port quickchart 3008 >/dev/null 2>&1 && bad "quickchart publica porta no host" || ok "quickchart sem porta no host"

echo; echo "PASSOU $PASS · FALHOU $FAIL"
[ "$FAIL" = 0 ]
