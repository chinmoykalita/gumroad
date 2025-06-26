import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Stats } from "$app/components/Stats";

export type ChurnTotals = {
  churn_rate: number;
  last_period_churn_rate: number;
  revenue_lost_cents: number;
  churned_users: number;
};

export const ChurnQuickStats = ({ total }: { total: ChurnTotals | undefined }) => (
  <div className="stats-grid">
    <Stats
      title={
        <>
          Churn rate
        </>
      }
      value={total ? `${total.churn_rate.toFixed(1)}%` : ""}
    />
    <Stats
      title={
        <>
          Last period churn rate
        </>
      }
      value={total ? `${total.last_period_churn_rate.toFixed(1)}%` : ""}
    />
    <Stats
      title={
        <>
          Revenue lost
        </>
      }
      value={
        total
          ? formatPriceCentsWithCurrencySymbol("usd", total.revenue_lost_cents, {
              symbolFormat: "short",
              noCentsIfWhole: true,
            })
          : ""
      }
    />
    <Stats
      title={
        <>
          Churned users
        </>
      }
      value={total ? total.churned_users.toLocaleString() : ""}
    />
  </div>
);
