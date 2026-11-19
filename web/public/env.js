/**
 * ENV variables for the application.
 * This file will be loaded into window object in runtime.
 * The values will be injected via the respective Helm Charts for the env.
 *
 * Example:-
 * ${API_BASE_PATH} will be replaced with API_BASE_PATH value from the helm chart template.
 * ${AUTH_BASE_PATH} will be replaced with AUTH_BASE_PATH value from the helm chart template.
 */
window.__ENV__ = {
  API_BASE_PATH: '${API_BASE_PATH}',
  AUTH_BASE_PATH: '${AUTH_BASE_PATH}',
  FULLSTORY_ORG_ID: '${FULLSTORY_ORG_ID}',
  FULLSTORY_DEV_MODE: Boolean('${FULLSTORY_DEV_MODE}'),
};
