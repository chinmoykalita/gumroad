import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type ChurnDataPoint = {
  churn_rate: number;
  churned_users: number;
  revenue_lost_cents: number;
  title: string;
  label: string;
};

export type ChurnData = {
  chart_points: ChurnDataPoint[];
  totals: {
    churn_rate: number;
    last_period_churn_rate: number;
    revenue_lost_cents: number;
    churned_users: number;
  };
  first_sale_date: string | null;
};

export const fetchChurnData = ({
  startTime,
  endTime,
  aggregateBy = "day",
  productIds,
}: {
  startTime: string;
  endTime: string;
  aggregateBy?: "day" | "month";
  productIds?: string[];
}) => {
  const abort = new AbortController();
  const params: Record<string, string | string[]> = {
    start_time: startTime,
    end_time: endTime,
    aggregate_by: aggregateBy,
  };

  if (productIds && productIds.length > 0) {
    params.product_ids = productIds;
  }

  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.analytics_churn_data_path(params),
    abortSignal: abort.signal,
  })
    .then((r) => r.json())
    .then((json) => cast<ChurnData>(json));
  return { response, abort };
};
