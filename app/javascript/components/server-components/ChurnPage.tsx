import { lightFormat } from "date-fns";
import * as React from "react";
import { createCast } from "ts-safe-cast";
import { register } from "$app/utils/serverComponentUtil";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { ProductsPopover } from "$app/components/Analytics/ProductsPopover";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { ChurnQuickStats, ChurnTotals } from "$app/components/Analytics/ChurnQuickStats";
import { ChurnChart, ChurnDataPoint } from "$app/components/Analytics/ChurnChart";
import { Progress } from "$app/components/Progress";
import { fetchChurnDataByDate, ChurnDataByDate } from "$app/data/churn_analytics";
import { AbortError } from "$app/utils/request";
import { showAlert } from "$app/components/server-components/Alert";

type Product = {
  name: string;
  id: string;
  alive: boolean;
  unique_permalink: string;
};

const ChurnPage = ({ products: initialProducts }: { products: Product[] }) => {
  const dateRange = useAnalyticsDateRange();
  const [products, setProducts] = React.useState(
    initialProducts.map((p) => ({ ...p, selected: p.alive }))
  );
  const [aggregateBy, setAggregateBy] = React.useState<"daily" | "monthly">("daily");

  const [dataByDate, setDataByDate] = React.useState<ChurnDataByDate | null>(null);

  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const selectedProductIds = React.useMemo(
    () => products.filter((p) => p.selected).map((p) => p.id),
    [products]
  );

  const hasSelectedProducts = selectedProductIds.length > 0;

  const activeRequest = React.useRef<AbortController | null>(null);
  React.useEffect(() => {
    const loadData = async () => {
      try {
        if (activeRequest.current) activeRequest.current.abort();
        setDataByDate(null);

        const requestParams = hasSelectedProducts
          ? { startTime, endTime, aggregateBy, productIds: selectedProductIds }
          : { startTime, endTime, aggregateBy };

        const req = fetchChurnDataByDate(requestParams);
        activeRequest.current = req.abort;
        const json = await req.response;
        setDataByDate(json);
        activeRequest.current = null;
      } catch (e) {
        console.error(e);
        if (e instanceof AbortError) return;
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    };
    void loadData();
  }, [startTime, endTime, aggregateBy, selectedProductIds, hasSelectedProducts]);

  const totals: ChurnTotals | undefined = dataByDate
    ? {
        churn_rate: dataByDate.total.churn_rate,
        last_period_churn_rate: dataByDate.last_period?.churn_rate || 0,
        revenue_lost_cents: dataByDate.total.revenue_lost_cents,
        churned_users: dataByDate.total.churned_users,
      }
    : undefined;

  const chartData: ChurnDataPoint[] = React.useMemo(() => {
    if (!dataByDate) return [];
    return dataByDate.dates.map((date, index) => ({
      churn_rate: dataByDate.by_date.churn_rate[index] || 0,
      churned_users: dataByDate.by_date.churned_users[index] || 0,
      revenue_lost_cents: dataByDate.by_date.revenue_lost_cents[index] || 0,
      title: date,
      label: index === 0 ? dataByDate.start_date : index === dataByDate.dates.length - 1 ? dataByDate.end_date : "",
    }));
  }, [dataByDate]);

  return (
    <AnalyticsLayout
      selectedTab="churn"
      actions={
        <>
          <select aria-label="Aggregate by" value={aggregateBy} onChange={(e) => setAggregateBy(e.target.value === "daily" ? "daily" : "monthly")}>
            <option value="daily">Daily</option>
            <option value="monthly">Monthly</option>
          </select>
          <ProductsPopover products={products} setProducts={setProducts} />
          <DateRangePicker {...dateRange} />
        </>
      }
    >
      {hasSelectedProducts ? (
        <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
          <ChurnQuickStats total={totals} />
          {chartData.length ? (
            <ChurnChart data={chartData} />
          ) : (
            <div className="input">
              <Progress width="1em" />
              Loading chart...
            </div>
          )}
        </div>
      ) : (
        <div className="input" style={{ textAlign: "center", padding: "var(--spacer-7)" }}>
          <p style={{ color: "var(--muted)", margin: 0 }}>
            No products selected. Please select at least one product to view churn analytics.
          </p>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default register({ component: ChurnPage, propParser: createCast<{ products: Product[] }>() });
