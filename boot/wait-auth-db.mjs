// Waits until the backend has applied the migrations this frontend was built
// against, so Better Auth's first schema check sees its tables.
//
// Better Auth >= 1.7 caches a schema mismatch for the life of the process:
// a frontend that answers one auth request before the backend has migrated
// keeps answering 500 "Database schema mismatch" until it restarts. On
// Railway the frontend is up in seconds and the backend needs about a minute.
//
// Ready = platform._prisma_migrations has a finished row for the newest
// migration in the pinned upstream release (baked into the image at build
// time). Checking only for the tables is not enough: later migrations add
// columns to them, and Better Auth compares columns too.
//
//   node wait-auth-db.mjs <timeoutSeconds>   exit 0 ready, 1 timed out
import { createRequire } from "node:module";
import { existsSync, readdirSync, readFileSync } from "node:fs";

const require = createRequire(import.meta.url);

function loadPg() {
  try {
    return require(require.resolve("pg", { paths: ["/app"] }));
  } catch {
    // standalone output keeps pnpm's layout: node_modules/.pnpm/pg@x/node_modules/pg
    const store = "/app/node_modules/.pnpm";
    const dir = existsSync(store) && readdirSync(store).find((d) => d.startsWith("pg@"));
    if (!dir) throw new Error("pg module not found in the image");
    return require(`${store}/${dir}/node_modules/pg`);
  }
}

const timeout = Number(process.argv[2] || 240);
const schema = process.env.AUTH_DB_SCHEMA || "platform";
const expected =
  process.env.AUTH_DB_EXPECTED_MIGRATION ||
  readFileSync(new URL("./latest-migration", import.meta.url), "utf8").trim();
const { Client } = loadPg();

async function ready() {
  const client = new Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5000 });
  try {
    await client.connect();
    const r = await client.query(
      `SELECT 1 FROM "${schema.replace(/"/g, '""')}"."_prisma_migrations"
        WHERE migration_name = $1 AND finished_at IS NOT NULL AND rolled_back_at IS NULL`,
      [expected],
    );
    return r.rowCount > 0;
  } catch {
    return false; // database not up yet, or no migrations table yet
  } finally {
    await client.end().catch(() => {});
  }
}

const deadline = Date.now() + timeout * 1000;
let said = false;
while (Date.now() < deadline) {
  if (await ready()) {
    console.log(`auth db: migrations through ${expected} are applied`);
    process.exit(0);
  }
  if (!said) {
    console.log(`auth db: waiting for the backend to apply migrations through ${expected}...`);
    said = true;
  }
  await new Promise((r) => setTimeout(r, 3000));
}
process.exit(1);
