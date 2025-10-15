TOKEN=$(curl -s -X POST http://localhost:7700/issue \
  -H 'Content-Type: application/json' \
  -d '{"service_id":"accounts"}' | jq -r .access_token | tr -d '\r\n"')
export TOKEN



curl -s -X POST http://localhost:7700/introspect \
  -H "Authorization: Bearer $TOKEN" | jq

  curl -i http://localhost:8080/accounts -H "Authorization: Bearer $TOKEN" | head -n1




  # Clean it just in case
CLEAN_TOKEN=$(echo -n "$TOKEN" | tr -d '\r\n"')
echo "len=$(printf %s "$CLEAN_TOKEN" | wc -c) first16=${CLEAN_TOKEN:0:16}"

# Pass to k6 using -e (sometimes safer than inline env)
k6 run -e STOLEN_TOKEN="$CLEAN_TOKEN" k6/replay.js


#Restart cleanly

docker compose down -v
docker image prune -f
docker compose up --build -d
docker compose ps
# expected output : auth       0.0.0.0:7070->7000/tcp



