import * as React from "react";
import { XAxis, YAxis, Line, Area } from "recharts";

import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Chart, xAxisProps, yAxisProps, lineProps } from "$app/components/Chart";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

export type ChurnDataPoint = {
  churn_rate: number;
  churned_users: number;
  revenue_lost_cents: number;
  title: string;
  label: string;
};

const ChartTooltip = ({ data }: { data: ChurnDataPoint }) => (
  <>
    <div>
      <strong>{data.churn_rate.toFixed(1)}%</strong> churn
    </div>
    {data.churned_users > 0 ? (
      <div>
        <strong>{data.churned_users}</strong> {data.churned_users === 1 ? "cancellation" : "cancellations"}
      </div>
    ) : null}
    {data.revenue_lost_cents > 0 ? (
      <div>
        <strong>
          {formatPriceCentsWithCurrencySymbol("usd", data.revenue_lost_cents, {
            symbolFormat: "short",
            noCentsIfWhole: true,
          })}
        </strong> revenue lost
      </div>
    ) : null}
    <time>{data.title}</time>
  </>
);

export const ChurnChart = ({ data }: { data: ChurnDataPoint[] }) => {
  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? data[tooltip.index] : null;

  return (
    <Chart
      color="info"
      containerRef={containerRef}
      tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
      tooltipPosition={tooltip?.position ?? null}
      data={data}
      {...events}
    >
      <XAxis {...xAxisProps} dataKey="label" />
      <YAxis
        {...yAxisProps}
        orientation="left"
        tickFormatter={(value: number) => `${value}%`}
        domain={[0, 4]}
      />
      <YAxis {...yAxisProps} yAxisId="rightPlaceholder" orientation="right" tick={false} width={40} domain={[0, 1]} />
      <Area
        type="monotone"
        dataKey="churn_rate"
        stroke="none"
        fill="rgba(var(--accent) / 0.1)"
        dot={false}
        isAnimationActive={false}
      />
      <Line {...lineProps(dotRef, data.length)} dataKey="churn_rate" stroke="rgb(var(--accent))" />
    </Chart>
  );
};
