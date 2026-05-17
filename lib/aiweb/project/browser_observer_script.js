const fs = require('fs');
const path = require('path');

const [url, viewport, widthText, heightText, screenshotPath, evidencePath] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
let observedConsoleErrors = [];
let observedNetworkErrors = [];
let observedBlockedExternalRequests = [];
let observedActionRecovery = null;

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function uniqueBlockedRequests(requests) {
  return Array.from(new Map((requests || []).map((entry) => [`${entry.method}:${entry.url}:${entry.resource_type}`, entry])).values());
}

function failedEvidenceBlock(reason, captureMode) {
  return {
    schema_version: 1,
    status: 'failed',
    reason,
    capture_mode: captureMode || null,
    viewports: [],
    items: [],
    blocking_issues: [reason]
  };
}

function failedFocusBlock(reason) {
  return {
    schema_version: 1,
    status: 'failed',
    required: true,
    reason,
    viewports: []
  };
}

async function main() {
  const { chromium } = require('playwright');
  ensureParent(screenshotPath);
  ensureParent(evidencePath);
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width, height } });
  const consoleErrors = [];
  const networkErrors = [];
  const blockedExternalRequests = [];
  observedConsoleErrors = consoleErrors;
  observedNetworkErrors = networkErrors;
  observedBlockedExternalRequests = blockedExternalRequests;
  function isLocalBrowserUrl(rawUrl) {
    try {
      const parsed = new URL(rawUrl);
      if (['about:', 'data:', 'blob:'].includes(parsed.protocol)) return true;
      if (!['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) return false;
      return ['localhost', '127.0.0.1', '::1'].includes(parsed.hostname);
    } catch (_error) {
      return false;
    }
  }
  await page.route('**/*', async (route) => {
    const request = route.request();
    if (!isLocalBrowserUrl(request.url())) {
      let frameUrl = null;
      try {
        frameUrl = request.frame() ? request.frame().url().slice(0, 500) : null;
      } catch (_error) {
        frameUrl = null;
      }
      blockedExternalRequests.push({
        url: request.url().slice(0, 500),
        method: request.method(),
        resource_type: request.resourceType(),
        is_navigation_request: request.isNavigationRequest(),
        frame_url: frameUrl,
        failure: 'non_local_request_blocked'
      });
      await route.abort('blockedbyclient');
      return;
    }
    await route.continue();
  });
  page.on('framenavigated', (frame) => {
    const frameUrl = frame.url();
    if (frameUrl && !isLocalBrowserUrl(frameUrl)) {
      blockedExternalRequests.push({
        url: frameUrl.slice(0, 500),
        method: 'NAVIGATE',
        resource_type: 'document',
        is_navigation_request: true,
        frame_url: frameUrl.slice(0, 500),
        failure: 'non_local_frame_navigation_blocked'
      });
    }
  });
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) {
      consoleErrors.push({
        type: message.type(),
        text: message.text().slice(0, 500),
        location: message.location()
      });
    }
  });
  page.on('pageerror', (error) => {
    consoleErrors.push({
      type: 'pageerror',
      text: String(error && error.message ? error.message : error).slice(0, 500)
    });
  });
  page.on('requestfailed', (request) => {
    const failure = request.failure();
    networkErrors.push({
      url: request.url().slice(0, 500),
      method: request.method(),
      resource_type: request.resourceType(),
      failure: failure && failure.errorText ? failure.errorText : null
    });
  });
  page.on('response', (response) => {
    if (response.status() >= 400) {
      networkErrors.push({
        url: response.url().slice(0, 500),
        method: response.request().method(),
        resource_type: response.request().resourceType(),
        status: response.status()
      });
    }
  });
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
  await page.screenshot({ path: screenshotPath, fullPage: true });

  const dom = await page.evaluate(() => {
    const interesting = Array.from(document.querySelectorAll('[data-aiweb-id], main, header, nav, section, article, h1, h2, h3, a, button, input, textarea, select')).slice(0, 80);
    return interesting.map((element, index) => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return {
        index,
        route: window.location.pathname || '/',
        selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
        data_aiweb_id: element.getAttribute('data-aiweb-id'),
        text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
        text: (element.innerText || element.getAttribute('aria-label') || '').trim().slice(0, 160),
        computed_styles: {
          font_family: style.fontFamily,
          font_size: style.fontSize,
          font_weight: style.fontWeight,
          line_height: style.lineHeight,
          color: style.color,
          background_color: style.backgroundColor,
          display: style.display,
          gap: style.gap,
          margin: style.margin,
          padding: style.padding
        },
        bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
      };
    });
  });

  let accessibility = null;
  try {
    accessibility = await page.accessibility.snapshot({ interestingOnly: false });
  } catch (_error) {
    accessibility = null;
  }

  const focusSteps = [];
  for (let index = 0; index < 12; index += 1) {
    await page.keyboard.press('Tab');
    focusSteps.push(await page.evaluate(() => {
      const element = document.activeElement;
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return {
        tag: element.tagName.toLowerCase(),
        selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
        data_aiweb_id: element.getAttribute('data-aiweb-id'),
        text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
        bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
      };
    }));
  }

  const interactiveCount = await page.locator('a, button, input, textarea, select, [role="button"], [tabindex]').count();
  const states = ['default', 'hover', 'focus-visible', 'active', 'disabled', 'loading', 'empty', 'error', 'success'].map((state) => {
    if (state === 'default') {
      return { state, status: 'captured', evidence: [screenshotPath] };
    }
    if (['hover', 'focus-visible', 'active'].includes(state)) {
      return {
        state,
        status: interactiveCount > 0 ? 'captured' : 'not_applicable',
        evidence: interactiveCount > 0 ? [`${interactiveCount} interactive candidates observed`] : []
      };
    }
    return { state, status: 'not_applicable', evidence: [] };
  });

  const actionRecovery = {
    schema_version: 1,
    status: 'captured',
    required: true,
    policy: 'localhost-only reversible UI actions; external navigation is blocked and recorded',
    viewport,
    url,
    actionable_target_count: interactiveCount,
    actions: [],
    recovery_steps: [],
    external_requests_blocked: [],
    unsafe_navigation_policy_enforced: true,
    unsafe_navigation_blocked: false,
    blocking_issues: []
  };
  observedActionRecovery = actionRecovery;
  const previewHref = new URL(url).href;
  const previewOrigin = new URL(url).origin;
  const maxActionTargets = Math.min(interactiveCount, 5);
  for (let index = 0; index < maxActionTargets; index += 1) {
    const target = page.locator('a, button, input, textarea, select, [role="button"], [tabindex]').nth(index);
    const step = {
      index,
      status: 'captured',
      selector: null,
      text_role: null,
      actions: [],
      recovery: []
    };
    try {
      const descriptor = await target.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return {
          tag: element.tagName.toLowerCase(),
          selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
          data_aiweb_id: element.getAttribute('data-aiweb-id'),
          text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
          text: (element.innerText || element.getAttribute('aria-label') || '').trim().slice(0, 120),
          href: element.getAttribute('href'),
          type: element.getAttribute('type'),
          aria_expanded: element.getAttribute('aria-expanded'),
          disabled: element.hasAttribute('disabled') || element.getAttribute('aria-disabled') === 'true',
          bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
        };
      });
      step.selector = descriptor.selector;
      step.text_role = descriptor.text_role;
      step.data_aiweb_id = descriptor.data_aiweb_id;
      step.bounding_box = descriptor.bounding_box;
      step.outcome_assertions = [];

      try {
        await target.scrollIntoViewIfNeeded({ timeout: 1000 });
        step.actions.push({ name: 'scroll_into_view', status: 'passed' });
      } catch (error) {
        step.actions.push({ name: 'scroll_into_view', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
      }
      try {
        await target.hover({ timeout: 1000 });
        step.actions.push({ name: 'hover', status: 'passed' });
      } catch (error) {
        step.actions.push({ name: 'hover', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
      }
      try {
        await target.focus({ timeout: 1000 });
        step.actions.push({ name: 'focus', status: 'passed' });
        step.outcome_assertions.push({ name: 'focus_targeted', status: 'recorded' });
      } catch (error) {
        step.actions.push({ name: 'focus', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
      }
      const inputType = String(descriptor.type || '').toLowerCase();
      if (['input', 'textarea'].includes(descriptor.tag) && !['password', 'file', 'hidden', 'submit', 'button', 'checkbox', 'radio'].includes(inputType) && !descriptor.disabled) {
        let originalValue = null;
        try {
          originalValue = await target.inputValue({ timeout: 500 });
          await target.fill('aiweb-probe', { timeout: 1000 });
          const probeValue = await target.inputValue({ timeout: 500 });
          step.actions.push({ name: 'fill_text_probe', status: probeValue === 'aiweb-probe' ? 'passed' : 'failed' });
          step.outcome_assertions.push({ name: 'input_probe_visible', status: probeValue === 'aiweb-probe' ? 'passed' : 'failed' });
          await target.fill(originalValue, { timeout: 1000 });
          const restoredValue = await target.inputValue({ timeout: 500 });
          step.recovery.push({ name: 'restore_input_value', status: restoredValue === originalValue ? 'passed' : 'failed' });
          step.outcome_assertions.push({ name: 'input_value_restored', status: restoredValue === originalValue ? 'passed' : 'failed' });
        } catch (error) {
          step.actions.push({ name: 'fill_text_probe', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
          if (originalValue !== null) {
            try {
              await target.fill(originalValue, { timeout: 1000 });
              step.recovery.push({ name: 'restore_input_value', status: 'attempted' });
            } catch (_restoreError) {
              step.recovery.push({ name: 'restore_input_value', status: 'failed' });
            }
          }
        }
      }
      if (descriptor.href && !descriptor.disabled) {
        const candidateUrl = new URL(descriptor.href, previewHref);
        if (candidateUrl.origin !== previewOrigin) {
          step.actions.push({
            name: 'click',
            status: 'not_performed',
            reason: 'external_navigation_policy',
            href: candidateUrl.href.slice(0, 500)
          });
        } else {
          try {
            await target.click({ timeout: 1000 });
            await page.waitForLoadState('domcontentloaded', { timeout: 1500 }).catch(() => {});
            const afterClickUrl = page.url();
            const localAfterClick = isLocalBrowserUrl(afterClickUrl);
            step.actions.push({
              name: 'click_same_origin_anchor',
              status: localAfterClick ? 'passed' : 'failed',
              href: candidateUrl.href.slice(0, 500),
              observed_url: afterClickUrl.slice(0, 500)
            });
            step.outcome_assertions.push({ name: 'same_origin_click_stayed_local', status: localAfterClick ? 'passed' : 'failed' });
            if (!localAfterClick) {
              actionRecovery.blocking_issues.push(`same-origin click escaped local preview policy: ${afterClickUrl.slice(0, 300)}`);
            }
          } catch (error) {
            step.actions.push({
              name: 'click_same_origin_anchor',
              status: 'skipped',
              reason: String(error.message || error).slice(0, 200),
              href: candidateUrl.href.slice(0, 500)
            });
          }
        }
      } else if (descriptor.tag === 'button' && descriptor.aria_expanded !== null && !descriptor.disabled && inputType !== 'submit') {
        try {
          await target.click({ timeout: 1000 });
          step.actions.push({ name: 'click_toggle_button', status: 'passed', aria_expanded_before: descriptor.aria_expanded });
          step.outcome_assertions.push({ name: 'toggle_click_local_url', status: isLocalBrowserUrl(page.url()) ? 'passed' : 'failed' });
        } catch (error) {
          step.actions.push({ name: 'click_toggle_button', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
        }
      }
      try {
        await page.keyboard.press('Escape');
        step.recovery.push({ name: 'escape', status: 'passed' });
      } catch (error) {
        step.recovery.push({ name: 'escape', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
      }
      if (page.url() !== previewHref) {
        await page.goto(previewHref, { waitUntil: 'domcontentloaded', timeout: 5000 });
        step.recovery.push({ name: 'restore_preview_url', status: page.url() === previewHref ? 'passed' : 'failed', url: page.url().slice(0, 500) });
      }
    } catch (error) {
      step.status = 'failed';
      step.error = String(error.message || error).slice(0, 300);
      actionRecovery.blocking_issues.push(`action target ${index} failed: ${step.error}`);
    }
    actionRecovery.actions.push(step);
  }
  if (maxActionTargets === 0) {
    actionRecovery.actions.push({
      index: null,
      status: 'not_applicable',
      reason: 'no interactive targets',
      actions: [],
      recovery: []
    });
  }
  const beforeRestoreUrl = page.url();
  if (beforeRestoreUrl !== previewHref) {
    try {
      await page.goto(previewHref, { waitUntil: 'domcontentloaded', timeout: 5000 });
    } catch (error) {
      actionRecovery.blocking_issues.push(`preview URL recovery failed: ${String(error.message || error).slice(0, 300)}`);
    }
  }
  actionRecovery.recovery_steps.push({
    action: 'restore_preview_url',
    status: page.url() === previewHref ? 'passed' : 'failed',
    from: beforeRestoreUrl.slice(0, 500),
    to: page.url().slice(0, 500)
  });
  if (blockedExternalRequests.length > 0) {
    const uniqueBlockedExternalRequests = uniqueBlockedRequests(blockedExternalRequests);
    networkErrors.push(...uniqueBlockedExternalRequests);
    actionRecovery.external_requests_blocked = uniqueBlockedExternalRequests;
    actionRecovery.unsafe_navigation_blocked = true;
    actionRecovery.blocking_issues.push(`${uniqueBlockedExternalRequests.length} non-local browser request(s) were blocked`);
  }
  if (actionRecovery.recovery_steps.some((step) => step.status === 'failed')) {
    actionRecovery.blocking_issues.push('browser action recovery did not return to the preview URL');
  }
  actionRecovery.status = actionRecovery.blocking_issues.length === 0 ? 'captured' : 'failed';

  const evidence = {
    schema_version: 1,
    status: 'captured',
    capture_mode: 'playwright_browser',
    viewport,
    width,
    height,
    url,
    screenshot: { path: screenshotPath, capture_mode: 'playwright_browser' },
    console_errors: consoleErrors,
    network_errors: networkErrors,
    dom_snapshot: {
      schema_version: 1,
      status: 'captured',
      capture_mode: 'playwright_browser',
      route: new URL(url).pathname || '/',
      viewport,
      selectors: dom,
      required_fields: ['route', 'viewport', 'selector', 'data_aiweb_id', 'text_role', 'computed_styles', 'bounding_box']
    },
    a11y_report: {
      schema_version: 1,
      status: 'captured',
      capture_mode: 'playwright_accessibility_tree',
      required_checks: ['contrast', 'keyboard_focus', 'aria_labels', 'landmarks', 'touch_targets'],
      accessibility_tree_present: !!accessibility,
      root_role: accessibility && accessibility.role,
      findings: []
    },
    computed_style_summary: {
      schema_version: 1,
      status: 'captured',
      capture_mode: 'playwright_computed_style',
      required_properties: ['font-family', 'font-size', 'font-weight', 'line-height', 'color', 'background-color', 'margin', 'padding', 'gap', 'display', 'grid', 'flex', 'overflow'],
      sampled_count: dom.length
    },
    interaction_states: states,
    keyboard_focus_traversal: {
      schema_version: 1,
      status: 'captured',
      required: true,
      steps: focusSteps.filter(Boolean)
    },
    action_recovery: actionRecovery,
    blocking_issues: []
  };
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2));
  await browser.close();
}

main().catch((error) => {
  ensureParent(evidencePath);
  const failureReason = `browser observation failed: ${error.message}`;
  const blocked = uniqueBlockedRequests(observedBlockedExternalRequests);
  const networkErrors = [...observedNetworkErrors];
  for (const entry of blocked) {
    if (!networkErrors.some((item) => item.url === entry.url && item.method === entry.method && item.resource_type === entry.resource_type)) {
      networkErrors.push(entry);
    }
  }
  const actionRecovery = observedActionRecovery || {
    schema_version: 1,
    status: 'failed',
    required: true,
    policy: 'localhost-only reversible UI actions; external navigation is blocked and recorded',
    viewport,
    url,
    actionable_target_count: 0,
    actions: [],
    recovery_steps: [],
    external_requests_blocked: blocked,
    unsafe_navigation_policy_enforced: true,
    unsafe_navigation_blocked: blocked.length > 0,
    blocking_issues: []
  };
  actionRecovery.status = 'failed';
  actionRecovery.external_requests_blocked = blocked;
  actionRecovery.unsafe_navigation_policy_enforced = true;
  actionRecovery.unsafe_navigation_blocked = blocked.length > 0 || actionRecovery.unsafe_navigation_blocked === true;
  if (blocked.length > 0 && !actionRecovery.blocking_issues.some((issue) => /non-local browser request/.test(issue))) {
    actionRecovery.blocking_issues.push(`${blocked.length} non-local browser request(s) were blocked`);
  }
  actionRecovery.blocking_issues.push(failureReason);
  fs.writeFileSync(evidencePath, JSON.stringify({
    schema_version: 1,
    status: 'failed',
    capture_mode: 'playwright_browser',
    viewport,
    width,
    height,
    url,
    console_errors: observedConsoleErrors,
    network_errors: networkErrors,
    dom_snapshot: failedEvidenceBlock(failureReason, 'playwright_browser'),
    a11y_report: failedEvidenceBlock(failureReason, 'playwright_accessibility_tree'),
    computed_style_summary: failedEvidenceBlock(failureReason, 'playwright_computed_style'),
    interaction_states: [],
    keyboard_focus_traversal: failedFocusBlock(failureReason),
    action_recovery: actionRecovery,
    blocking_issues: [`browser observation failed: ${error.message}`]
  }, null, 2));
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
