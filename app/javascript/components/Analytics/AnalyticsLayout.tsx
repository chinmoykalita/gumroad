import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

export const AnalyticsLayout = ({
  selectedTab,
  children,
  actions,
}: {
  selectedTab: "following" | "sales" | "utm_links" | "churn";
  children: React.ReactNode;
  actions?: React.ReactNode;
}) => {
  const user = assertDefined(useLoggedInUser());
  const currentSeller = assertDefined(useCurrentSeller());

  const { churn_analytics_enabled } = useFeatureFlags();

  return (
    <div>
      <PageHeader title="Analytics" actions={actions}>
        <Tabs>
          <Tab href={Routes.audience_dashboard_path()} isSelected={selectedTab === "following"}>
            Following
          </Tab>
          <Tab href={Routes.sales_dashboard_path()} isSelected={selectedTab === "sales"}>
            Sales
          </Tab>
          {churn_analytics_enabled && currentSeller.has_subscription_products ? (
            <Tab href={Routes.churn_dashboard_path()} isSelected={selectedTab === "churn"}>
              Churn
            </Tab>
          ) : null}
          {user.policies.utm_link.index ? (
            <Tab href={Routes.utm_links_dashboard_path()} isSelected={selectedTab === "utm_links"}>
              Links
            </Tab>
          ) : null}
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};
