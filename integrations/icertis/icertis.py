#!/usr/bin/env python3
"""
Icertis to Veza OAA Integration Script

Collects identity and permission data from Icertis Contract Intelligence
(users, groups, and org units) and pushes it to Veza's Access Graph via
the Open Authorization API (OAA).

Auth: OAuth 2.0 — Client Credentials grant
"""

import argparse
import json
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

import requests
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log = logging.getLogger(__name__)


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def load_config(args) -> dict:
    """Load configuration from .env file, environment variables, and CLI args.

    Precedence: CLI arg → environment variable → .env file.
    """
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)

    return {
        "veza_url":                   args.veza_url          or os.getenv("VEZA_URL"),
        "veza_api_key":               args.veza_api_key      or os.getenv("VEZA_API_KEY"),
        "icertis_api_url":            args.api_url           or os.getenv("ICERTIS_API_URL"),
        "icertis_business_api_url":   args.business_api_url  or os.getenv("ICERTIS_BUSINESS_API_URL"),
        "icertis_token_url":          args.token_url         or os.getenv("ICERTIS_TOKEN_URL"),
        "icertis_client_id":          args.client_id         or os.getenv("ICERTIS_CLIENT_ID"),
        "icertis_client_secret":      args.client_secret     or os.getenv("ICERTIS_CLIENT_SECRET"),
        "icertis_scope":              args.scope             or os.getenv(
            "ICERTIS_SCOPE",
            "api://6c49748d-db77-4577-b9d0-e31330bc889c/.default",
        ),
    }


def _validate_config(config: dict, dry_run: bool) -> None:
    """Exit with a clear error if required config values are absent."""
    source_required = {
        "ICERTIS_API_URL":          config["icertis_api_url"],
        "ICERTIS_BUSINESS_API_URL": config["icertis_business_api_url"],
        "ICERTIS_TOKEN_URL":        config["icertis_token_url"],
        "ICERTIS_CLIENT_ID":        config["icertis_client_id"],
        "ICERTIS_CLIENT_SECRET":    config["icertis_client_secret"],
    }
    missing = [k for k, v in source_required.items() if not v]
    if missing:
        log.error("Missing required source configuration: %s", ", ".join(missing))
        print(f"ERROR: Missing required configuration: {', '.join(missing)}")
        sys.exit(1)

    if not dry_run:
        veza_required = {
            "VEZA_URL":     config["veza_url"],
            "VEZA_API_KEY": config["veza_api_key"],
        }
        missing = [k for k, v in veza_required.items() if not v]
        if missing:
            log.error("Missing required Veza configuration: %s", ", ".join(missing))
            print(f"ERROR: Missing required Veza configuration: {', '.join(missing)}")
            sys.exit(1)


# ---------------------------------------------------------------------------
# OAuth2 Token
# ---------------------------------------------------------------------------


def get_access_token(
    token_url: str,
    client_id: str,
    client_secret: str,
    scope: str,
) -> str:
    """Obtain an OAuth2 Bearer token using the Client Credentials grant."""
    log.info("Requesting OAuth2 access token from %s", token_url)

    payload = {
        "grant_type":    "client_credentials",
        "client_id":     client_id,
        "client_secret": client_secret,
        "scope":         scope,
    }

    try:
        response = requests.post(token_url, data=payload, timeout=30)
        response.raise_for_status()
    except requests.exceptions.HTTPError as exc:
        log.error("Token request failed (HTTP %s): %s", exc.response.status_code, exc)
        sys.exit(1)
    except requests.exceptions.RequestException as exc:
        log.error("Token request failed: %s", exc)
        sys.exit(1)

    token_data = response.json()
    token = token_data.get("access_token")
    if not token:
        log.error("Access token not found in token response: %s", list(token_data.keys()))
        sys.exit(1)

    log.info("OAuth2 access token obtained successfully")
    return token


# ---------------------------------------------------------------------------
# Icertis API Client
# ---------------------------------------------------------------------------


class IcertisClient:
    """Lightweight wrapper around the Icertis REST API."""

    PAGE_SIZE = 100

    def __init__(self, api_url: str, business_api_url: str, token: str) -> None:
        self.api_url = api_url.rstrip("/")
        self.business_api_url = business_api_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Accept":        "application/json",
                "Content-Type":  "application/json",
            }
        )

    def _get(self, base_url: str, path: str, params: dict = None) -> dict:
        """Make an authenticated GET request and return parsed JSON."""
        url = f"{base_url}{path}"
        try:
            response = self.session.get(url, params=params, timeout=30)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.HTTPError as exc:
            log.error("HTTP error on GET %s: %s", url, exc)
            raise
        except requests.exceptions.RequestException as exc:
            log.error("Request error on GET %s: %s", url, exc)
            raise

    @staticmethod
    def _unwrap(result) -> list:
        """Normalise Icertis paginated response — handles 'value', 'data', or bare list."""
        if isinstance(result, list):
            return result
        return result.get("value") or result.get("data") or []

    def get_users(self) -> list:
        """Retrieve all Icertis users with pagination."""
        log.info("Fetching Icertis users")
        users, page = [], 1
        while True:
            log.debug("  users page %d", page)
            result = self._get(self.api_url, "/api/Users", params={"page": page, "pageSize": self.PAGE_SIZE})
            batch = self._unwrap(result)
            if not batch:
                break
            users.extend(batch)
            if len(batch) < self.PAGE_SIZE:
                break
            page += 1
        log.info("Total users retrieved: %d", len(users))
        return users

    def get_groups(self) -> list:
        """Retrieve all Icertis groups with pagination."""
        log.info("Fetching Icertis groups")
        groups, page = [], 1
        while True:
            log.debug("  groups page %d", page)
            result = self._get(self.api_url, "/api/Groups", params={"page": page, "pageSize": self.PAGE_SIZE})
            batch = self._unwrap(result)
            if not batch:
                break
            groups.extend(batch)
            if len(batch) < self.PAGE_SIZE:
                break
            page += 1
        log.info("Total groups retrieved: %d", len(groups))
        return groups

    def get_org_units(self) -> list:
        """Retrieve all Icertis organizational units."""
        log.info("Fetching Icertis org units")
        result = self._get(self.business_api_url, "/api/v1/organizationunits")
        org_units = self._unwrap(result)
        log.info("Total org units retrieved: %d", len(org_units))
        return org_units

    def get_group_members(self, group_id: str) -> list:
        """Retrieve member list for a specific group."""
        try:
            result = self._get(self.api_url, f"/api/Groups/{group_id}/members")
            return self._unwrap(result)
        except requests.exceptions.RequestException:
            log.warning("Could not fetch members for group %s — skipping", group_id)
            return []

    def build_membership_map(self, groups: list) -> dict:
        """Return {user_id: [group_name, ...]} by iterating each group's member list.

        Used as a fallback when group memberships are not embedded in the user object.
        """
        log.info("Building group membership map from %d groups", len(groups))
        memberships: dict = {}
        for grp in groups:
            grp_id   = str(grp.get("id") or grp.get("Id") or "")
            grp_name = grp.get("name") or grp.get("Name") or grp_id
            if not grp_id:
                continue
            for member in self.get_group_members(grp_id):
                uid = str(member.get("id") or member.get("Id") or "")
                if uid:
                    memberships.setdefault(uid, []).append(grp_name)
        log.info("Membership map built — %d users with group assignments", len(memberships))
        return memberships


# ---------------------------------------------------------------------------
# OAA Payload Builder
# ---------------------------------------------------------------------------


def build_oaa_payload(
    users: list,
    groups: list,
    org_units: list,
    membership_map: dict,
    args,
) -> CustomApplication:
    """Assemble the OAA CustomApplication payload from Icertis data."""

    app = CustomApplication(
        name=args.datasource_name,
        application_type=args.provider_name,
    )

    # --- Custom permissions -----------------------------------------------
    app.add_custom_permission("view",    [OAAPermission.DataRead])
    app.add_custom_permission("create",  [OAAPermission.DataRead, OAAPermission.DataWrite])
    app.add_custom_permission("edit",    [OAAPermission.DataRead, OAAPermission.DataWrite])
    app.add_custom_permission("submit",  [OAAPermission.DataRead, OAAPermission.DataWrite])
    app.add_custom_permission("approve", [
        OAAPermission.DataRead,
        OAAPermission.DataWrite,
        OAAPermission.MetadataRead,
    ])
    app.add_custom_permission("manage",  [
        OAAPermission.DataRead,
        OAAPermission.DataWrite,
        OAAPermission.MetadataRead,
        OAAPermission.MetadataWrite,
        OAAPermission.NonData,
    ])

    # --- Custom user properties -------------------------------------------
    app.property_definitions.define_local_user_property("department",    "string")
    app.property_definitions.define_local_user_property("org_unit_id",   "string")
    app.property_definitions.define_local_user_property("org_unit_name", "string")

    # --- Org units as Application Resources --------------------------------
    log.info("Adding %d org units as resources", len(org_units))
    ou_name_map: dict = {}  # id → name for later user assignment
    for ou in org_units:
        ou_id   = str(ou.get("id") or ou.get("Id") or "")
        ou_name = ou.get("name") or ou.get("Name") or ou_id
        if not ou_id:
            log.warning("Org unit missing id field — skipping: %s", ou)
            continue
        app.add_resource(
            resource_key=ou_id,
            resource_type="OrgUnit",
            name=ou_name,
            description=ou.get("description") or ou.get("Description") or "",
        )
        ou_name_map[ou_id] = ou_name
        log.debug("Added org unit resource: %s (%s)", ou_name, ou_id)

    # --- Groups as Local Groups -------------------------------------------
    log.info("Adding %d groups as local groups", len(groups))
    for grp in groups:
        grp_id   = str(grp.get("id") or grp.get("Id") or "")
        grp_name = grp.get("name") or grp.get("Name") or grp_id
        if not grp_id:
            log.warning("Group missing id field — skipping: %s", grp)
            continue
        app.add_local_group(
            name=grp_name,
            unique_id=grp_id,
        )
        log.debug("Added group: %s (%s)", grp_name, grp_id)

    # --- Users as Local Users ---------------------------------------------
    log.info("Adding %d users as local users", len(users))
    for user in users:
        user_id = str(user.get("id") or user.get("Id") or "")
        email   = (
            user.get("email")     or user.get("Email")
            or user.get("loginName") or user.get("LoginName")
            or ""
        )
        name    = (
            user.get("displayName") or user.get("DisplayName")
            or user.get("name")     or user.get("Name")
            or email
        )
        status  = str(
            user.get("isActive") or user.get("IsActive")
            or user.get("status")  or user.get("Status")
            or "true"
        ).lower()
        is_active = status not in ("false", "inactive", "disabled", "0")

        if not user_id:
            log.warning("User missing id field — skipping: %s", user)
            continue

        local_user = app.add_local_user(
            name=email or name,
            identities=[email] if email else [],
            unique_id=user_id,
        )
        local_user.is_active = is_active

        # Optional properties
        dept = user.get("department") or user.get("Department") or ""
        if dept:
            local_user.set_property("department", dept)

        ou_id = str(user.get("organizationalUnitId") or user.get("OrganizationalUnitId") or "")
        if ou_id:
            local_user.set_property("org_unit_id", ou_id)
            ou_name = ou_name_map.get(ou_id, "")
            if ou_name:
                local_user.set_property("org_unit_name", ou_name)
            # Grant view permission on the user's org unit resource
            if ou_id in ou_name_map:
                local_user.add_permission("view", resources=[ou_id], apply_to_sub_resources=False)

        # Group membership — first check embedded field, then fall back to map
        embedded_groups = user.get("groups") or user.get("Groups") or []
        if embedded_groups:
            for ug in embedded_groups:
                ug_name = ug.get("name") or ug.get("Name") or str(ug.get("id") or ug.get("Id") or "")
                if ug_name:
                    try:
                        local_user.add_group(ug_name)
                    except Exception as exc:
                        log.warning("Could not add user %s to group %s: %s", email, ug_name, exc)
        else:
            for grp_name in membership_map.get(user_id, []):
                try:
                    local_user.add_group(grp_name)
                except Exception as exc:
                    log.warning("Could not add user %s to group %s: %s", email, grp_name, exc)

        log.debug("Added user: %s (%s), active=%s", name, user_id, is_active)

    log.info(
        "OAA payload assembled — users: %d  groups: %d  org units: %d",
        len(users), len(groups), len(org_units),
    )
    return app


# ---------------------------------------------------------------------------
# Veza Push
# ---------------------------------------------------------------------------


def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: bool = False,
) -> None:
    """Optionally save payload as JSON and push to Veza (skipped on dry-run)."""

    if save_json:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        slug = datasource_name.lower().replace(" ", "_")
        json_path = os.path.join(script_dir, f"{slug}_payload.json")
        with open(json_path, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("Payload saved to %s", json_path)
        print(f"Payload saved: {json_path}")

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        print("[DRY RUN] Payload built successfully — skipping Veza push")
        return

    log.info("Pushing OAA payload to Veza: %s", veza_url)
    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza")
        print("Successfully pushed to Veza")
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error, exc.message, exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Icertis → Veza OAA Integration. "
            "Pushes Icertis users, groups, and org units to the Veza Access Graph."
        )
    )

    # General
    parser.add_argument("--env-file",        default=".env",   help="Path to .env file (default: .env)")
    parser.add_argument("--dry-run",         action="store_true", help="Build payload without pushing to Veza")
    parser.add_argument("--save-json",       action="store_true", help="Save OAA payload as JSON for inspection")
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity (default: INFO)",
    )

    # Veza
    parser.add_argument("--veza-url",        default=None, help="Veza tenant URL (env: VEZA_URL)")
    parser.add_argument("--veza-api-key",    default=None, help="Veza API key (env: VEZA_API_KEY)")
    parser.add_argument("--provider-name",   default="Icertis", help="Provider name in Veza (default: Icertis)")
    parser.add_argument("--datasource-name", default="Icertis", help="Datasource name in Veza (default: Icertis)")

    # Icertis source
    parser.add_argument("--api-url",          default=None, help="Icertis API base URL for users/groups (env: ICERTIS_API_URL, e.g. https://<tenant>-api.icertis.com)")
    parser.add_argument("--business-api-url", default=None, help="Icertis Business API base URL for org units (env: ICERTIS_BUSINESS_API_URL, e.g. https://<tenant>-business-api.icertis.com)")
    parser.add_argument("--token-url",        default=None, help="OAuth2 token endpoint (env: ICERTIS_TOKEN_URL)")
    parser.add_argument("--client-id",       default=None, help="OAuth2 client ID (env: ICERTIS_CLIENT_ID)")
    parser.add_argument("--client-secret",   default=None, help="OAuth2 client secret (env: ICERTIS_CLIENT_SECRET)")
    parser.add_argument(
        "--scope",
        default=None,
        help=(
            "OAuth2 scope value (env: ICERTIS_SCOPE, "
            "default: api://6c49748d-db77-4577-b9d0-e31330bc889c/.default)"
        ),
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    print("=" * 60)
    print(" Icertis → Veza OAA Integration")
    print("=" * 60)

    args = parse_args()
    _setup_logging(args.log_level)
    log.info("Starting Icertis OAA integration")

    config = load_config(args)
    _validate_config(config, args.dry_run)

    # --- Authenticate -------------------------------------------------------
    token = get_access_token(
        token_url=config["icertis_token_url"],
        client_id=config["icertis_client_id"],
        client_secret=config["icertis_client_secret"],
        scope=config["icertis_scope"],
    )

    # --- Fetch data ---------------------------------------------------------
    client = IcertisClient(
        api_url=config["icertis_api_url"],
        business_api_url=config["icertis_business_api_url"],
        token=token,
    )
    users     = client.get_users()
    groups    = client.get_groups()
    org_units = client.get_org_units()

    # Build membership map (used if group memberships are not embedded in users)
    membership_map = client.build_membership_map(groups)

    # --- Build OAA payload --------------------------------------------------
    app = build_oaa_payload(users, groups, org_units, membership_map, args)

    # --- Push to Veza -------------------------------------------------------
    push_to_veza(
        veza_url=config["veza_url"],
        veza_api_key=config["veza_api_key"],
        provider_name=args.provider_name,
        datasource_name=args.datasource_name,
        app=app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    log.info("Icertis OAA integration completed successfully")
    print("Done.")


if __name__ == "__main__":
    main()
