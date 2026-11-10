import i18n from 'i18next';
import { showSuccess } from '@ifs-ds/helix-web-components/base';
import { HttpError } from '@ifs-kairos/net/http';
import {
  createCustomResponseRule,
  responseFromHttpResponseText,
  registerServerResponses,
  type ResponseConfig,
  type ServerResponseResolver,
} from '@ifs-kairos/response';
import { t } from './i18n';

/**
 * API envelope message ID → translator.
 *
 * IDs must match the message IDs your Client API sends in the response
 * envelope (`message` / `messageId`). Optional `messageParams` fill `{{Name}}`
 * slots at toast time.
 *
 * Use the two-string form `i18n.t(key, defaultValue)` (params as 3rd arg) so
 * `pnpm i18n:extract` can pick up keys. Resolvers run when the toast is shown,
 * not at module load, so locale switches work.
 *
 * This map ships empty in the template. Each bounded context adds its own
 * entries here. After adding keys, run `pnpm i18n:extract` and translate
 * overrides in locale JSON as needed.
 *
 * @example
 * ORDER_CREATED: (params) =>
 *   i18n.t('status.ORDER_CREATED', 'Order {{OrderId}} was created', params),
 */
const serverResponses = {
  // ORDER_CREATED: (params) =>
  //   i18n.t('status.ORDER_CREATED', 'Order {{OrderId}} was created', params),
} as const satisfies Record<string, ServerResponseResolver>;

export type ServerResponseId = keyof typeof serverResponses;

export function isServerResponseId(id: string): id is ServerResponseId {
  return Object.hasOwn(serverResponses, id);
}

// BC catalog → runtime resolver.
registerServerResponses(serverResponses);

function envelopeResponse(response: HttpError, fallback: string): string {
  return responseFromHttpResponseText(response.responseText, fallback);
}

/** Non-error HTTP responses (2xx Kairos envelopes with a known status ID). */
const httpSuccessRule = createCustomResponseRule<HttpError>({
  trigger: (response) =>
    response.status >= 200 &&
    response.status < 300 &&
    envelopeResponse(response, '').length > 0,
  logToConsole: false,
  notifyUser: true,
  notifyUserCallbacks: [
    (response) => {
      void showSuccess(
        envelopeResponse(response, ''),
        i18n.t('status.toast.success', 'Success'),
      );
    },
  ],
});

function alertClientError(ev: ErrorEvent): void {
  const userMessage = t(
    'error.client.message',
    'Something went wrong in the browser. Consider reloading.',
  );
  const technical =
    ev.error instanceof Error ? ev.error.message : ev.message || String(ev.error ?? '');
  window.alert(technical ? `${userMessage}\n\n${technical}` : userMessage);
}

export const responseConfig: ResponseConfig = {
  customResponseRules: [httpSuccessRule],
  clientResponseRule: {
    logToConsole: true,
    notifyUser: true,
    notifyUserCallbacks: [alertClientError],
  },
};
