# Authentication, SSO, and Service-Account Auth

Companion to `skills/org-management/SKILL.md`. Console SSO providers, SAML configuration, CLI authentication flows, service-account token handling, REST API auth.

## Console Authentication (SSO)

The Console uses single sign-on with these providers:

| Provider | Notes |
|:---|:---|
| **Google** | OAuth-based SSO |
| **GitHub** | OAuth-based SSO |
| **Microsoft** | OAuth-based SSO |
| **SAML** | Enterprise SSO — contact support@controlplane.com to enable |

### SAML configuration values

| Setting | Value |
|:---|:---|
| Service Provider Entity ID | `cpln.io` |
| ACS / Callback URL | `https://console.cpln.io/__/auth/handler` |

Your SAML provider must supply: Entity ID, SSO URL, and Certificate.

After SSO, user access is determined by their [group](https://docs.controlplane.com/reference/group.md) membership and [policies](https://docs.controlplane.com/reference/policy.md).

## CLI Authentication

**Interactive login** (opens browser):

```bash
cpln login
```

Creates a `default` profile. Optionally specify a profile name:

```bash
cpln login my-profile
```

**Service account token** (browser-less / CI/CD):

```bash
cpln profile create PROFILE_NAME --token TOKEN --org ORG_NAME --gvc GVC_NAME --default
```

**Environment variable:**

```bash
export CPLN_TOKEN=your-service-account-token
```

## Token Precedence

The CLI resolves tokens in this order:

1. `--token` flag (highest priority).
2. `CPLN_TOKEN` environment variable.
3. Profile token (default).

## Service Account Authentication

For CI/CD, automation, and programmatic access:

### 1. Create the service account and generate a key

```bash
cpln serviceaccount create --name SA_NAME --org ORG
cpln serviceaccount add-key SA_NAME --description "What this key is for" --org ORG
```

`add-key` **requires `--description`** and prints a JSON object:

```json
{
  "description": "What this key is for",
  "created": "2026-04-24T12:00:00.000Z",
  "key": "SERVICE_ACCOUNT_KEY_VALUE"
}
```

Extract the value from the `key` property — that is the token. The key is shown **only once**; save it immediately to a secret store (password manager, CI secret, vault).

### 2. Grant permissions

Add the service account to a group (or create a policy with the service account as a principal). See **cpln-access-control** for policies, bindings, and group membership.

### 3. Use the key as a token

Prefer the `CPLN_TOKEN` environment variable or a profile over passing `--token` on the command line — CLI flags can leak into shell history and CI logs. For full CI/CD setup (GitHub Actions, GitLab CI, etc.), see the **cpln-gitops-cicd** skill.

## REST API Authentication

```bash
curl --request GET \
  --url https://api.cpln.io/org/ORG_NAME/gvc \
  --header 'Authorization: Bearer YOUR_TOKEN'
```

Tokens can come from a service account key or `cpln profile token PROFILE_NAME`.
