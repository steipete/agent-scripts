// dseditgroup reports non-members with exit 67; other failures are unknown.
export function adminMembership({ status, stdout }) {
  const text = (stdout || "").trim();
  if (status === 0 && /^yes .+ is a member of admin\.?$/i.test(text)) return true;
  if (status === 67 && /^no .+ is NOT a member of admin\.?$/i.test(text)) return false;
  return null;
}
