interface EnvConfig {
  API_BASE_PATH: string;
  AUTH_BASE_PATH: string;
  // Fullstory
  FULLSTORY_ORG_ID: string;
  FULLSTORY_DEV_MODE: boolean;
}

interface Window {
  __ENV__: EnvConfig;
}
