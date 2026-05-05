# Icertis Sample Data

Place representative Icertis API response samples in this directory before running a local dry-run test. The integration script will not be modified — samples are used by the `OAA Dry-Run Tester` agent to validate the payload offline.

## Required Files

### `users.json`
A JSON array (or paginated API response) from `GET /api/v2/users`.

Minimum fields needed:

```json
[
  {
    "id": "usr-001",
    "displayName": "Jane Smith",
    "email": "jane.smith@example.com",
    "isActive": true,
    "department": "Legal",
    "organizationalUnitId": "ou-001",
    "groups": [
      { "id": "grp-001", "name": "Contract Managers" }
    ]
  }
]
```

### `groups.json`
A JSON array from `GET /api/v2/groups`.

```json
[
  {
    "id": "grp-001",
    "name": "Contract Managers",
    "description": "Users who manage contracts"
  }
]
```

### `org_units.json`
A JSON array from `GET /api/v2/organizationalunits`.

```json
[
  {
    "id": "ou-001",
    "name": "Legal Operations",
    "description": "Legal department org unit"
  }
]
```

## How to Collect Samples

Use `curl` with a valid Bearer token (obtained from the token endpoint):

```bash
TOKEN=$(curl -s -X POST "$ICERTIS_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=$ICERTIS_CLIENT_ID" \
  -d "client_secret=$ICERTIS_CLIENT_SECRET" \
  -d "scope=$ICERTIS_SCOPE" | jq -r '.access_token')

curl -s -H "Authorization: Bearer $TOKEN" \
  "$ICERTIS_BASE_URL/api/v2/users?page=1&pageSize=5" > samples/users.json

curl -s -H "Authorization: Bearer $TOKEN" \
  "$ICERTIS_BASE_URL/api/v2/groups?page=1&pageSize=5" > samples/groups.json

curl -s -H "Authorization: Bearer $TOKEN" \
  "$ICERTIS_BASE_URL/api/v2/organizationalunits" > samples/org_units.json
```

Once sample files are in place, re-run the `OAA Dry-Run Tester` agent to validate the payload.
