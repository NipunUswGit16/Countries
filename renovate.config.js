const config = {
  platform: "bitbucket",
  baseDir: `${process.env.BITBUCKET_CLONE_DIR}/renovate`,
  username: process.env.KAIROS_RENOVATE_BITBUCKET_USERNAME,
  password: process.env.KAIROS_RENOVATE_BITBUCKET_PASSWORD,
  baseBranches: ["main"],
  repositories: [
    `ifs-pd/${process.env.BITBUCKET_REPO_SLUG}`,
  ],
  enabledManagers: ["gomod"],
  constraints: {
    "go": "1.27.3"
  },
  postUpdateOptions: [
    "gomodUpdateImportPaths",
    "gomodTidy",
    "gomodSkipVendor"
  ],
  hostRules: [
    {
      "matchHost": "https://bitbucket.org/ifs-pd",
      "token": process.env.RENOVATE_GO_TOKEN || process.env.KAIROS_BB_ACCESS_TOKEN,
      "hostType": "go"
    }
  ],
  ignoreDeps: [
    "bitbucket.org/ifs-pd/countries/pkg/schema"
  ],
  packageRules: [
    {
      matchPackageNames: ["github.com/swaggo/swag"],
      allowedVersions: "<2.0.0",
    },
  ],
  autodiscover: false,
  onboarding: false,
  reviewers: ["ifs-nidees", "ifs-cslues", "ifs-viares", "ifsmarese"],
  customEnvVariables: {
    "GOPRIVATE": "bitbucket.org/ifs-pd",
    "GONOSUMDB": "bitbucket.org/ifs-pd",
    "GONOPROXY": "bitbucket.org/ifs-pd"
  },
};

// CHANGE-3222: Renovate needs a personal Bitbucket API token (Atlassian email + ATAT…
// password). Do not use KAIROS_BB_ACCESS_TOKEN for platform auth — workspace access
// tokens only expose project/pipeline scopes and cannot call /user or pullrequests APIs.
if (process.env.RENOVATE_BITBUCKET_PASSWORD) {
  config.username =
    process.env.RENOVATE_BITBUCKET_EMAIL || process.env.RENOVATE_BITBUCKET_USERNAME;
  config.password = process.env.RENOVATE_BITBUCKET_PASSWORD;
}

if (process.env.RENOVATE_BITBUCKET_AUTHOR) {
  config.gitAuthor = process.env.RENOVATE_BITBUCKET_AUTHOR;
} else if (process.env.RENOVATE_BITBUCKET_EMAIL) {
  config.gitAuthor = `Renovate Bot <${process.env.RENOVATE_BITBUCKET_EMAIL}>`;
}

if (process.env.RENOVATE_BITBUCKET_PRIVATEKEY) {
  config.gitPrivateKey = process.env.RENOVATE_BITBUCKET_PRIVATEKEY.replace(/\|/g, "\n");
}

module.exports = config;
