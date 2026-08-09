function messageOf(value) {
  if (value instanceof Error && value.message) return value.message;
  return String(value);
}

function collect(error, depth, lines) {
  const indent = depth > 0 ? '  '.repeat(depth - 1) : '';
  lines.push(`${indent}${depth > 0 ? '- ' : ''}${messageOf(error)}`);
  if (!Array.isArray(error?.errors)) return;
  for (const nested of error.errors) collect(nested, depth + 1, lines);
}

export function formatError(error) {
  const lines = [];
  collect(error, 0, lines);
  return lines.join('\n');
}
