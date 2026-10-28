#!/usr/bin/env bash
# Run inside the image as agent: Playwright Chromium tests a page served by DinD.
set -Eeuo pipefail
test_dir=$(mktemp -d)
cleanup() {
    docker rm -f browser-smoke >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
test "$(id -un)" = agent
cd "$test_dir"

printf '<!doctype html><meta charset="utf-8"><title>Browser smoke</title><h1>Zażółć gęślą jaźń</h1>\n' > index.html
docker run -d --name browser-smoke -p 7779:80 nginx:1.29-alpine >/dev/null
docker cp index.html browser-smoke:/usr/share/nginx/html/index.html

npm init -y >/dev/null
npm install --no-audit --no-fund @playwright/test@1.64.1 >/dev/null
npx playwright install chromium
cat > browser.spec.js <<'JS'
const { test, expect } = require('@playwright/test');
test('renders a page from a DinD container', async ({ page }) => {
    await page.goto('http://127.0.0.1:7779/');
    await expect(page.locator('h1')).toHaveText('Zażółć gęślą jaźń');
    await page.screenshot({ path: 'page.png', fullPage: true });
    await page.pdf({ path: 'page.pdf' });
});
JS
npx playwright test browser.spec.js --reporter=line
file page.png | grep -F 'PNG image data'
file page.pdf | grep -F 'PDF document'
echo 'Browser tests passed: Playwright Chromium, DinD-served page, screenshot and PDF.'
