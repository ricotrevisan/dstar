import fs from "node:fs";
import { chromium } from "playwright";

const cases = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const browser = await chromium.launch({headless: true});
const page = await browser.newPage();
await page.setContent("<!doctype html><body></body>");

const results = [];
for (const testCase of cases) {
  const result = await page.evaluate((input) => {
    document.body.dataset.dsBase = input.dsBase || "";
    const calls = [];
    let alerted = false;
    const action = (url) => calls.push(url);
    const source = input.expression.replace(/^@(get|post|put|patch|delete)/, "action");

    try {
      const execute = new Function(
        "location",
        "document",
        "$_dstar_module",
        "action",
        "alert",
        source
      );

      execute(
        {
          origin: "https://app.test",
          pathname: input.pathname || "/workspace/page",
          search: input.search || ""
        },
        document,
        input.dynamicModule,
        action,
        () => { alerted = true; }
      );

      const resolved = calls[0] == null ? null : new URL(calls[0], "https://app.test/base");
      const rawSegments = resolved == null ? [] : resolved.pathname.split("/").filter(Boolean);

      return {
        alerted,
        callCount: calls.length,
        origin: resolved?.origin || null,
        pathname: resolved?.pathname || null,
        rawSegments,
        decodedSegments: rawSegments.map((segment) => decodeURIComponent(segment))
      };
    } catch (error) {
      return {alerted, callCount: calls.length, error: String(error)};
    }
  }, testCase);

  results.push(result);
}

await browser.close();
process.stdout.write(JSON.stringify(results));
