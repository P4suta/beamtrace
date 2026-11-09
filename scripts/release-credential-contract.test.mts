// SPDX-License-Identifier: Apache-2.0 OR MIT
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { isDeepStrictEqual } from "node:util";
import { parseDocument, stringify } from "yaml";

type Fields = Record<string, unknown>;
type Kind = "proposal" | "verify";
type Layout = {
	path: string;
	job: string;
	event: string;
	runner: string;
	timeout: number;
};

const layouts: Record<Kind, Layout> = {
	proposal: {
		path: "release-please.yml",
		job: "release-please",
		event: "push",
		runner: "ubuntu-latest",
		timeout: 10,
	},
	verify: {
		path: "verify-doppler.yml",
		job: "automation_0",
		event: "workflow_dispatch",
		runner: "ubuntu-latest",
		timeout: 5,
	},
};
const client = `\${{ secrets.RELEASE_APP_CLIENT_ID }}`;
const key = `\${{ secrets.RELEASE_APP_PRIVATE_KEY }}`;
const validInputs =
	"secrets.RELEASE_APP_CLIENT_ID != '' && !startsWith(secrets.RELEASE_APP_CLIENT_ID, '${') && secrets.RELEASE_APP_PRIVATE_KEY != '' && !startsWith(secrets.RELEASE_APP_PRIVATE_KEY, '${')";

function isFields(value: unknown): value is Fields {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fields(value: unknown): Fields {
	assert.ok(isFields(value));
	return value;
}

function isList(value: unknown): value is unknown[] {
	return Array.isArray(value);
}

function list(value: unknown): unknown[] {
	assert.ok(isList(value));
	return value;
}

function text(value: unknown): string {
	assert.equal(typeof value, "string");
	assert.ok(typeof value === "string");
	return value;
}

function keysAre(value: Fields, keys: readonly string[]): boolean {
	return Object.keys(value).every((key) => keys.includes(key));
}

function expression(value: unknown): string {
	return text(value)
		.trim()
		.replace(/^\$\{\{\s*|\s*\}\}$/g, "")
		.replace(/\s+/g, " ");
}

function label(value: unknown): boolean {
	return (
		typeof value === "string" && value.length > 0 && !value.includes("${{")
	);
}

function action(value: unknown, repository: string): boolean {
	if (typeof value !== "string") return false;
	const [name, sha, extra] = value.split("@");
	return (
		name === repository &&
		/^[a-f0-9]{40}$/.test(sha ?? "") &&
		extra === undefined
	);
}

function consumer(root: Fields, kind: Kind): Fields {
	return fields(fields(root.jobs)[layouts[kind].job]);
}

function tokenInputs(root: Fields, kind: Kind): Fields {
	return fields(fields(list(consumer(root, kind).steps)[1]).with);
}

function nativeWorkflow(source: string, kind: Kind): boolean {
	try {
		const document = parseDocument(source, {
			uniqueKeys: true,
			stringKeys: true,
		});
		if (document.errors.length > 0 || document.warnings.length > 0)
			return false;
		const parsed: unknown = document.toJS();
		const root = fields(parsed);
		const layout = layouts[kind];
		const trigger =
			kind === "proposal"
				? { push: { branches: ["main"] } }
				: { workflow_dispatch: null };
		if (
			!keysAre(root, ["name", "on", "permissions", "concurrency", "jobs"]) ||
			!label(root.name) ||
			!isDeepStrictEqual(root.on, trigger) ||
			!isDeepStrictEqual(root.permissions, {}) ||
			!isDeepStrictEqual(root.concurrency, {
				group:
					kind === "proposal" ? "release-please-main" : "verify-credentials",
				"cancel-in-progress": false,
			}) ||
			!isDeepStrictEqual(Object.keys(fields(root.jobs)), [layout.job])
		)
			return false;

		const job = consumer(root, kind);
		if (
			!keysAre(job, [
				"name",
				"if",
				"runs-on",
				"timeout-minutes",
				"environment",
				"permissions",
				"env",
				"steps",
			]) ||
			!label(job.name) ||
			job["runs-on"] !== layout.runner ||
			job["timeout-minutes"] !== layout.timeout ||
			job.environment !== "release-automation" ||
			!isDeepStrictEqual(job.permissions, {}) ||
			expression(job.if) !==
				`github.repository_id == '1343313550' && github.event_name == '${layout.event}' && github.ref == 'refs/heads/main'`
		)
			return false;
		const environment = fields(job.env);
		if (
			!isDeepStrictEqual(Object.keys(environment), ["APP_INPUTS_VALID"]) ||
			expression(environment.APP_INPUTS_VALID) !== validInputs
		)
			return false;

		const steps = list(job.steps);
		if (steps.length !== (kind === "proposal" ? 3 : 2)) return false;
		const validation = fields(steps[0]);
		if (
			!keysAre(validation, ["name", "if", "shell", "run"]) ||
			!label(validation.name) ||
			expression(validation.if) !== "env.APP_INPUTS_VALID != 'true'" ||
			validation.shell !== "bash" ||
			text(validation.run).trim() !== "exit 1"
		)
			return false;
		const token = fields(steps[1]);
		const permissions =
			kind === "proposal"
				? {
						"permission-contents": "write",
						"permission-pull-requests": "write",
						"permission-issues": "write",
					}
				: { "permission-contents": "read" };
		if (
			!keysAre(token, ["name", "id", "uses", "with"]) ||
			!label(token.name) ||
			token.id !== "app-token" ||
			!action(token.uses, "actions/create-github-app-token") ||
			!isDeepStrictEqual(token.with, {
				"client-id": client,
				"private-key": key,
				owner: `\${{ github.repository_owner }}`,
				repositories: "beamtrace",
				...permissions,
			})
		)
			return false;
		if (kind === "proposal") {
			const proposal = fields(steps[2]);
			if (
				!keysAre(proposal, ["name", "uses", "with"]) ||
				!label(proposal.name) ||
				!action(proposal.uses, "googleapis/release-please-action") ||
				!isDeepStrictEqual(proposal.with, {
					token: `\${{ steps.app-token.outputs.token }}`,
					"config-file": "release-please-config.json",
					"manifest-file": ".release-please-manifest.json",
				})
			)
				return false;
		}
		return true;
	} catch {
		return false;
	}
}

type Mutation = { name: string; change: (root: Fields, kind: Kind) => void };
const mutations: readonly Mutation[] = [
	{
		name: "another repository",
		change: (root, kind) => {
			consumer(root, kind).if = text(consumer(root, kind).if).replace(
				"1343313550",
				"1",
			);
		},
	},
	{
		name: "another ref",
		change: (root, kind) => {
			consumer(root, kind).if = text(consumer(root, kind).if).replace(
				"refs/heads/main",
				"refs/heads/untrusted",
			);
		},
	},
	{
		name: "another event",
		change: (root, kind) => {
			consumer(root, kind).if = text(consumer(root, kind).if).replace(
				layouts[kind].event,
				"pull_request",
			);
		},
	},
	{
		name: "unprotected environment",
		change: (root, kind) => {
			consumer(root, kind).environment = "unprotected";
		},
	},
	{
		name: "OIDC in the consumer job",
		change: (root, kind) => {
			consumer(root, kind).permissions = { "id-token": "write" };
		},
	},
	{
		name: "workflow write permission",
		change: (root) => {
			root.permissions = { contents: "write" };
		},
	},
	{
		name: "raw job credential",
		change: (root, kind) => {
			fields(consumer(root, kind).env).LEAK = key;
		},
	},
	{
		name: "another consumer",
		change: (root) => {
			fields(root.jobs).extra = { env: { LEAK: key } };
		},
	},
	{
		name: "repository-wide App token",
		change: (root, kind) => {
			tokenInputs(root, kind).repositories = "beamtrace,aozora";
		},
	},
	{
		name: "another installation owner",
		change: (root, kind) => {
			tokenInputs(root, kind).owner = "another-owner";
		},
	},
	{
		name: "workflow permission on the App token",
		change: (root, kind) => {
			tokenInputs(root, kind)["permission-workflows"] = "write";
		},
	},
	{
		name: "disabled token revocation",
		change: (root, kind) => {
			tokenInputs(root, kind)["skip-token-revoke"] = true;
		},
	},
	{
		name: "credential in a run step",
		change: (root, kind) => {
			list(consumer(root, kind).steps).push({ run: `echo ${key}` });
		},
	},
	{
		name: "token before validation",
		change: (root, kind) => {
			const steps = list(consumer(root, kind).steps);
			[steps[0], steps[1]] = [steps[1], steps[0]];
		},
	},
	{
		name: "another secret alias",
		change: (root, kind) => {
			tokenInputs(root, kind)["private-key"] =
				`\${{ secrets.UNRELATED_PRIVATE_KEY }}`;
		},
	},
	{
		name: "missing client ID",
		change: (root, kind) => {
			delete tokenInputs(root, kind)["client-id"];
		},
	},
	{
		name: "another token action",
		change: (root, kind) => {
			fields(list(consumer(root, kind).steps)[1]).uses =
				`untrusted/action@${"a".repeat(40)}`;
		},
	},
	{
		name: "another trigger",
		change: (root) => {
			fields(root.on).pull_request = null;
		},
	},
	{
		name: "bypassed input validation",
		change: (root, kind) => {
			fields(consumer(root, kind).env).APP_INPUTS_VALID = "true";
		},
	},
	{
		name: "inverted validation",
		change: (root, kind) => {
			fields(list(consumer(root, kind).steps)[0]).if =
				"env.APP_INPUTS_VALID == 'true'";
		},
	},
	{
		name: "job-wide Node options",
		change: (root, kind) => {
			fields(consumer(root, kind).env).NODE_OPTIONS =
				"--require ./untrusted.js";
		},
	},
	{
		name: "workflow-wide environment",
		change: (root) => {
			root.env = { LEAK: key };
		},
	},
	{
		name: "dynamic display name",
		change: (root) => {
			root.name = key;
		},
	},
];

for (const kind of ["proposal", "verify"] satisfies Kind[]) {
	const source = readFileSync(
		new URL(`../.github/workflows/${layouts[kind].path}`, import.meta.url),
		"utf8",
	);
	test(`${kind} credentials remain in the protected consumer`, async (t) => {
		assert.ok(nativeWorkflow(source, kind), layouts[kind].path);
		for (const mutation of mutations) {
			await t.test(`reject ${mutation.name}`, () => {
				const parsed: unknown = parseDocument(source).toJS();
				const root = fields(parsed);
				const before = structuredClone(root);
				mutation.change(root, kind);
				assert.notDeepEqual(root, before, "the fixture must change the source");
				assert.equal(nativeWorkflow(stringify(root), kind), false);
			});
		}
		assert.equal(
			nativeWorkflow(`${source}\npermissions: { contents: write }\n`, kind),
			false,
		);
	});
}
