import * as React from "react";

type FeatureFlags = {
  require_email_typo_acknowledgment: boolean;
  churn_analytics_enabled: boolean;
};

const FeatureFlagsContext = React.createContext<FeatureFlags>({
  require_email_typo_acknowledgment: false,
  churn_analytics_enabled: false,
});

export const FeatureFlagsProvider = FeatureFlagsContext.Provider;

export function useFeatureFlags() {
  return React.useContext(FeatureFlagsContext);
}
