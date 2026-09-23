#!/usr/bin/env python3
"""Assemble the mongosh seed scripts. Invoked by gen-seed.sh, not directly.

Reads .env plus the artifacts gen-seed.sh produced, and writes:
  scripts/seed-rootdb.js       root tenant + certificate + OIDC + admin user
  scripts/seed-permissions.js  one Permissions document per protected resource

Every write is an upsert keyed on a natural identifier, so applying the scripts
repeatedly is safe.
"""
import base64
import hashlib
import json
import os
import pathlib
import re
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
env = dict(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", (ROOT / ".env").read_text(), re.M))

TENANT = env["ROOT_TENANT_ID"]
ITEM_ID = env["TENANT_ITEM_ID"]
SALT = env["TENANT_SALT"]
CERT_PW = env["TENANT_CERT_PASSWORD"]
DOMAIN = env["DOMAIN"]
ADMIN_EMAIL = env["ADMIN_EMAIL"]
ADMIN_HASH = os.environ["ADMIN_HASH"]

# provider / display name exactly as configure.sh declares them, so configure.js
# matches these rows on its $or lookup instead of printing SKIP.
SERVICES = [
    ("os", "blocks OS"), ("iam", "blocks IAM"), ("data", "blocks DATA"),
    ("logic", "blocks LOGIC"), ("localization", "blocks LOCALIZATION"),
    ("studio", "blocks STUDIO"), ("release", "blocks RELEASE"),
    ("monitor", "blocks MONITOR"), ("agents", "blocks AGENTS"),
    ("utilities", "blocks UTILITIES"),
]

def url(svc):    return env[f"{svc.upper()}_URL"]
def client(svc): return env[f"{svc.upper()}_CLIENT_ID"]
def secret(svc): return env[f"{svc.upper()}_CLIENT_SECRET"]

IAM = url("iam")

# CertificateManager.GeneratePrivateCertificateName: sha256 hex of
# "<TenantId>::<ItemId>". MongodbCertificateProvider looks the blob up by it.
CERT_KEY = hashlib.sha256(f"{TENANT}::{ITEM_ID}".encode()).hexdigest()
PFX_B64 = base64.b64encode((ROOT / "certs/tenant.pfx").read_bytes()).decode()

tenant = {
    "_id": ITEM_ID, "TenantId": TENANT, "Name": "Blocks Root",
    # For the root tenant the tenant database *is* the root database: IAM
    # resolves OidcClientRegistrations/IdentityProviders through the ambient
    # tenant context, which maps to Tenant.DBName.
    "DBName": env["BlocksSecret__RootDatabaseName"],
    "DbConnectionString": env["TENANT_DB_CONNECTION_STRING"],
    "TenantSalt": SALT, "IsRootTenant": True, "IsDisabled": False,
    "IsAcceptBlocksTerms": True, "IsUseBlocksExclusively": False,
    "Environment": "dev", "TenantGroupId": str(uuid.uuid5(uuid.NAMESPACE_URL, TENANT)),
    "Applications": [
        {"Domain": url(s), "CookieDomain": DOMAIN, "IsDomainVerified": True}
        for s, _ in SERVICES
    ],
    "IsThirdPartyJwtEnabled": False, "ThirdPartyJwtTokenParameters": {},
    "JwtTokenParameters": {
        "Issuer": "SeliseBlocks", "Subject": "Selise-Blocks",
        "Audiences": [IAM],
        "PublicCertificatePath": "", "PublicCertificatePassword": CERT_PW,
        "PrivateCertificatePassword": CERT_PW,
        "CertificateStorageType": 3,          # Mongodb
        "CertificateValidForNumberOfDays": 730,
        # Required. Left unset it deserialises to 0001-01-01, and the cache TTL
        # JwksService derives from it becomes zero, which Redis rejects.
        "IssueDate": {"__now__": True},
    },
    "OrganizationId": "default", "Tags": [],
}

cert = {"_id": str(uuid.uuid5(uuid.NAMESPACE_URL, CERT_KEY)),
        "Key": CERT_KEY, "Value": PFX_B64, "OrganizationId": "default", "Tags": []}

registrations, providers = [], []
for svc, display in SERVICES:
    cid, u = client(svc), url(svc)
    registrations.append({
        "_id": cid, "ClientId": cid, "ClientSecret": secret(svc),
        "ClientName": f"Blocks {svc.upper()}",
        "RedirectUris": [u + "/login/callback"], "PostLogoutRedirectUris": [u],
        "AllowedScopes": ["openid", "profile", "email", "offline_access"],
        "AllowedResponseTypes": ["code"], "TokenEndpointAuthMethod": "client_secret_post",
        "RequirePkce": True, "RequireConsent": False, "IsActive": True,
        "UseTokensCookie": True, "RequireMfa": False, "IsDeviceFlowClient": False,
        "RegisterAsIdentityProvider": False, "OrganizationId": "default", "Tags": [],
    })
    providers.append({
        "_id": cid, "Provider": f"blocks-{svc}", "ProviderType": "internal",
        "Protocol": "oidc", "DisplayName": display, "IsActive": True,
        "ClientId": cid, "ClientSecret": secret(svc), "Issuer": IAM,
        "AuthorizationUrl": f"{IAM}/api/oidc/authorize?tenant_id={TENANT}",
        "TokenUrl": f"{IAM}/api/oidc/token?tenant_id={TENANT}",
        "UserInfoUrl": f"{IAM}/api/auth/userinfo?tenant_id={TENANT}",
        "JwksUri": f"{IAM}/{TENANT}/.well-known/jwks.json",
        "WellKnownUrl": f"{IAM}/{TENANT}/.well-known/openid-configuration",
        "RedirectUris": [u + "/login/callback"],
        "Scope": "openid profile email offline_access", "ResponseType": "code",
        "GrantTypes": ["authorization_code", "refresh_token"], "RequirePkce": True,
        "TokenEndpointAuthMethod": "client_secret_post",
        "InitialRoles": [], "InitialPermissions": [],
        "OrganizationId": "default", "Tags": [],
    })

# Genesis reads each service's configuration from a Secrets document at startup
# (AddMongoDbConfiguration, SecretKey "blocks-secret-<svc>") and throws if it is
# absent — so every service needs one before it can boot. configure.js fills in
# the KeyPairs afterwards but only ever updates, never inserts, so the documents
# have to exist first. "blocks-Secret" is the shared one configure.js also writes.
secrets = [{"_id": f"blocks-secret-{s_}", "SecretKey": f"blocks-secret-{s_}",
            "KeyPairs": {}, "OrganizationId": "default", "Tags": []}
           for s_, _ in SERVICES]
secrets.append({"_id": "blocks-Secret", "SecretKey": "blocks-Secret",
                "KeyPairs": {}, "OrganizationId": "default", "Tags": []})

# One of the sixteen BlocksConfiguration templates. Every field has a default in
# IdentityConfiguration.cs; this is a minimal stand-in, not SELISE's template.
identity_config = {
    "AllowedGrantTypes": ["authorization_code", "refresh_token", "password"],
    "IsOidcEnabled": True, "PublicCertificatePath": "",
    "AccountActivationPath": "/activate", "AccountVerificationPath": "/verify",
    "RecoverAccountPath": "/recover", "AccountActionBaseUrl": url("os"),
    "UseAccountActionBaseUrlAsDefault": True,
    "PasswordStrengthCheckerRegex": "", "PasswordStrengthCheckerMessage": "",
    "PasswordPolicyMinLength": 8, "PasswordPolicyMaxLength": 64,
    "PasswordPolicyMessage": "",
}

user_id = str(uuid.uuid5(uuid.NAMESPACE_URL, ADMIN_EMAIL))
user = {
    "_id": user_id, "Email": ADMIN_EMAIL, "UserName": ADMIN_EMAIL,
    "FirstName": "Blocks", "LastName": "Admin", "Password": ADMIN_HASH,
    "Active": True, "IsVerified": True,
    "VerifiedType": 1, "Status": 1, "UserPassType": 1, "UserCreationType": 1,
    "ProvisioningSource": 0, "Roles": {"default": ["admin"]}, "Permissions": {},
    "SecurityStamp": uuid.uuid4().hex, "TokenVersion": 1,
    "MfaEnabled": False, "UserMfaType": 0, "MfaMethods": [],
    "FailedLoginCount": 0, "LockoutCount": 0,
    "AllowedLogInType": [], "ExternalIdentities": [],
    "OrganizationIds": ["default"], "Attributes": {}, "Tags": [],
}
people = {
    "_id": str(uuid.uuid5(uuid.NAMESPACE_URL, user_id)), "UserId": user_id,
    "Email": ADMIN_EMAIL, "TenantId": TENANT,
    "IsInvitationSent": True, "IsInvitationConfirmed": True, "IsCreator": True,
    "Roles": ["admin"], "AccessPolicies": [], "OrganizationId": "default", "Tags": [],
}

js = f"""// Generated by scripts/gen-seed.sh — do not edit.
// Applied against BlocksRootDb. Every write is an upsert.
const now = new Date();
const stamp = d => Object.assign(d, {{ CreatedDate: now, LastUpdatedDate: now }});

const tenant = {json.dumps(tenant)};
tenant.JwtTokenParameters.IssueDate = now;
// delete+insert rather than replaceOne: _id is immutable, so a regenerated
// TENANT_ITEM_ID would otherwise fail against an existing tenant.
db.Tenants.deleteMany({{ TenantId: tenant.TenantId }});
db.Tenants.insertOne(stamp(tenant));

db.TenantCertificates.deleteMany({{ Key: "{CERT_KEY}" }});
db.TenantCertificates.insertOne(stamp({json.dumps(cert)}));

{json.dumps(registrations)}.forEach(r =>
  db.OidcClientRegistrations.replaceOne({{ ClientId: r.ClientId }}, stamp(r), {{ upsert: true }}));

{json.dumps(providers)}.forEach(p =>
  db.IdentityProviders.replaceOne({{ ClientId: p.ClientId }}, stamp(p), {{ upsert: true }}));

// Created empty; configure.js populates KeyPairs and cannot insert.
{json.dumps(secrets)}.forEach(d => {{
  if (!db.Secrets.findOne({{ SecretKey: d.SecretKey }})) db.Secrets.insertOne(stamp(d));
}});

if (db.IdentityConfigurations.countDocuments({{}}) === 0) {{
  db.IdentityConfigurations.insertOne({json.dumps(identity_config)});
}}

db.Users.deleteMany({{ Email: "{ADMIN_EMAIL}" }});
db.Users.insertOne(stamp({json.dumps(user)}));
db.ProjectPeoples.deleteMany({{ UserId: "{user_id}" }});
db.ProjectPeoples.insertOne(stamp({json.dumps(people)}));

print("  tenants=" + db.Tenants.countDocuments({{}})
    + " certs=" + db.TenantCertificates.countDocuments({{}})
    + " clients=" + db.OidcClientRegistrations.countDocuments({{}})
    + " idps=" + db.IdentityProviders.countDocuments({{}})
    + " secrets=" + db.Secrets.countDocuments({{}})
    + " users=" + db.Users.countDocuments({{}}));
"""
(ROOT / "scripts/seed-rootdb.js").write_text(js)

resources = [l.strip() for l in (ROOT / "scripts/permissions.txt").read_text().splitlines()
             if l.strip() and not l.startswith("#")]
perms = [{"_id": str(uuid.uuid5(uuid.NAMESPACE_URL, r)), "Resource": r,
          "Roles": ["admin"], "Permissions": [], "OrganizationId": "default",
          "Name": r.split("::")[-1], "Type": "endpoint", "Severity": "low", "Tags": []}
         for r in resources]

(ROOT / "scripts/seed-permissions.js").write_text(f"""// Generated by scripts/gen-seed.sh — do not edit.
// ProtectedEndpointAccessHandler resolves [ProtectedEndPoint] names against this
// collection; an empty collection makes every guarded endpoint return 403.
const now = new Date();
{json.dumps(perms)}.forEach(d => {{
  d.CreatedDate = now; d.LastUpdatedDate = now;
  // delete+insert: _id is immutable, so replaceOne fails against rows written
  // with a different id scheme.
  db.Permissions.deleteMany({{ Resource: d.Resource, OrganizationId: d.OrganizationId }});
  db.Permissions.insertOne(d);
}});
print("  permissions=" + db.Permissions.countDocuments({{}}));
""")

print(f"  scripts/seed-rootdb.js       ({len(registrations)} clients, {len(providers)} idps, 1 user)")
print(f"  scripts/seed-permissions.js  ({len(perms)} grants)")
