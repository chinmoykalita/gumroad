import { lightFormat } from "date-fns";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { fetchChurnData, ChurnData } from "$app/data/churn_analytics";
import { AbortError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { ChurnChart, ChurnDataPoint } from "$app/components/Analytics/ChurnChart";
import { ChurnQuickStats, ChurnTotals } from "$app/components/Analytics/ChurnQuickStats";
import { ProductsPopover } from "$app/components/Analytics/ProductsPopover";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";

type Product = {
  name: string;
  id: string;
  alive: boolean;
  unique_permalink: string;
};

type AggregateOption = {
  value: "day" | "month";
  title: string;
};

const ChurnPage = ({
  products: initialProducts,
  aggregate_options,
}: {
  products: Product[];
  aggregate_options: AggregateOption[];
}) => {
  const dateRange = useAnalyticsDateRange();
  const [products, setProducts] = React.useState(initialProducts.map((p) => ({ ...p, selected: p.alive })));
  const [aggregateBy, setAggregateBy] = React.useState<"day" | "month">("day");

  const [dataByDate, setDataByDate] = React.useState<ChurnData | null>(null);

  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const selectedProductIds = React.useMemo(() => products.filter((p) => p.selected).map((p) => p.id), [products]);

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

        const req = fetchChurnData(requestParams);
        activeRequest.current = req.abort;
        const json = await req.response;
        setDataByDate(json);
        activeRequest.current = null;
      } catch (error) {
        if (error instanceof AbortError) return;
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    };
    void loadData();
  }, [startTime, endTime, aggregateBy, selectedProductIds, hasSelectedProducts]);

  const totals: ChurnTotals | undefined = dataByDate ? dataByDate.totals : undefined;

  const chartData: ChurnDataPoint[] = React.useMemo(() => (dataByDate ? dataByDate.chart_points : []), [dataByDate]);

  return (
    <AnalyticsLayout
      selectedTab="churn"
      actions={
        <>
          <select
            aria-label="Aggregate by"
            className="w-auto"
            value={aggregateBy}
            onChange={(e) => {
              const value = e.target.value;
              if (value === "day" || value === "month") {
                setAggregateBy(value);
              }
            }}
          >
            {aggregate_options.map((option) => (
              <option key={option.value} value={option.value}>
                {option.title}
              </option>
            ))}
          </select>
          <ProductsPopover products={products} setProducts={setProducts} />
          <DateRangePicker {...dateRange} />
        </>
      }
    >
      <div style={{ display: "grid", gap: "var(--spacer-7)" }} className="p-4 md:p-8">
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
    </AnalyticsLayout>
  );
};

export default register({
  component: ChurnPage,
  propParser: createCast<{ products: Product[]; aggregate_options: AggregateOption[] }>(),
});
