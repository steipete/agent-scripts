import assert from "node:assert/strict";
import test from "node:test";
import { adminMembership } from "./admin-membership.mjs";

test("admin membership distinguishes members, non-members and failed checks", () => {
  assert.equal(adminMembership({status: 0, stdout: "yes synthetic is a member of admin\n"}), true);
  assert.equal(adminMembership({status: 67, stdout: "no synthetic is NOT a member of admin\n"}), false);
  for (const result of [
    {status: 1, stdout: ""}, {status: null, stdout: null},
    {status: 1, stdout: "no response from directory server"},
    {status: 0, stdout: "unexpected response"},
    {status: 1, stdout: "yes synthetic is a member of admin"},
    {status: 67, stderr: "no synthetic is NOT a member of admin"},
  ]) assert.equal(adminMembership(result), null);
});
