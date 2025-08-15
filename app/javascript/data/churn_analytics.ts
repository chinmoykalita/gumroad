import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

type ByDateArray = number[];

export type ChurnData = {
  dates: string[];
  start_date: string;
  end_date: string;
  by_date: {
    churn_rate: ByDateArray;
    churned_users: ByDateArray;
    revenue_lost_cents: ByDateArray;
  };
  total: {
    churn_rate: number;
    churned_users: number;
    revenue_lost_cents: number;
  };
  last_period?: {
    churn_rate: number;
    churned_users: number;
    revenue_lost_cents: number;
  };
};

export const fetchChurnData = ({
  startTime,
  endTime,
  aggregateBy = "daily",
  productIds,
}: {
  startTime: string;
  endTime: string;
  aggregateBy?: "daily" | "monthly";
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
