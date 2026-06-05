# Billing Account Management

Companion to `skills/org-management/SKILL.md`. Billing-account features, roles, user management, spend alerts, and the initial billing account creation flow.

A billing account manages user access, invoices, payment methods, and spending alerts. You can create multiple billing accounts.

## Billing Account Features

| Feature | Description |
|:---|:---|
| **Account Details** | Company information, billing contact |
| **Orgs** | View orgs linked to the billing account |
| **Invoices** | View and download invoices |
| **Payment Methods** | Add, update, or remove payment methods |
| **Users** | Manage billing user access and roles |
| **Cost & Usage** | Review costs across all orgs in the account |
| **Spend Alerts** | Email alerts when monthly spending hits a threshold |

## Billing Account Roles

| Role | Description |
|:---|:---|
| `billing_admin` | Full access to billing settings, invoices, and user management |
| `billing_viewer` | Read-only access to billing information |
| `org_creator` | Can create new organizations under the billing account |

**Billing roles vs org policies:** Billing roles control account-level access (invoices, payment, org creation). Org-level policies control resource-level access (workloads, secrets, etc.). They are **completely independent** — a `billing_admin` has zero implicit permissions on any org resource.

> Billing-account access is **Console-only** — there is no MCP tool or `cpln` command for billing roles. Do not confuse it with org-level access: org users, groups, and service accounts are managed via MCP tools (`mcp__cpln__invite_user_to_org`, `mcp__cpln__list_users` / `mcp__cpln__get_user` / `mcp__cpln__delete_user`, `mcp__cpln__create_group` / `mcp__cpln__edit_group`, `mcp__cpln__create_service_account` / `mcp__cpln__add_key_to_service_account`) — see `skills/org-management/SKILL.md`.

## Initial Billing Account Creation Flow (Console Only)

The initial billing account can only be created via the Console. The creation form collects:

- **Contact info**: full name, company, job title, phone (required), LinkedIn (optional).
- **Address**: country, city, postal code, address line 1 (required); state, line 2 (optional).
- **Org/GVC**: org name (required), GVC name (defaults to `default-gvc`), locations.
- **Payment**: Stripe integration for payment method.

## Managing Billing Users (Console Only)

1. Navigate to **Org Management & Billing** (profile icon → upper right).
2. Click **Users** in the left menu.
3. Add new user: enter email, select role(s), click **Add User**.
4. Edit existing user: click **Edit**, modify roles, click **Confirm**.

A user must have at least one role (`billing_admin`, `billing_viewer`, or `org_creator`). Users gain immediate access once added.

> These are **billing-account** users, not org members. To add or remove a user inside an org, use the org-level MCP tools (`mcp__cpln__invite_user_to_org`, `mcp__cpln__delete_user`), not this billing dashboard.

## Spend Threshold Alerts

Enable from Account Details. Set a monthly spending limit — you receive an email when the threshold is reached.
