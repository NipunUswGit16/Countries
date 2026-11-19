import '@testing-library/jest-dom/vitest';
import './src/config/i18n';
window.__ENV__ = {
    API_BASE_PATH: 'api/v1',
    AUTH_BASE_PATH: 'auth/v1',
    FULLSTORY_ORG_ID: '',
    FULLSTORY_DEV_MODE: true,
};
