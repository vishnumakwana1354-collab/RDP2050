//+------------------------------------------------------------------+
//|                                           TradingCostPlanner.mq5 |
//|          Copyright 2025, MetaQuotes Ltd. Developer is Chacha Ian |
//|                          https://www.mql5.com/en/users/chachaian |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd. Developer is Chacha Ian"
#property link      "https://www.mql5.com/en/users/chachaian"
#property version   "1.01"
#property strict
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Trade direction                                                  |
//+------------------------------------------------------------------+
enum ENUM_PLAN_DIRECTION
  {
   PLAN_BUY  = 0,   // Plan a market Buy
   PLAN_SELL = 1    // Plan a market Sell
  };

//--- Proposed trade
input group "Proposed trade"
input ENUM_PLAN_DIRECTION InpDirection                = PLAN_BUY; // Trade direction
input double              InpVolume                   = 0.01;     // Order volume in lots; estimates remain in points
input double              InpTargetMovePoints         = 100.0;    // Expected favorable midpoint move in points
input double              InpMinimumAfterSpreadPoints = 0.0;      // Advisory threshold after spread in points

//--- Historical spread scenario
input group "Historical spread scenario"
input int                 InpHistoryHours             = 24;       // Recent tick history in hours
input int                 InpStressPercentile         = 90;       // Historical spread percentile
input int                 InpMinimumHistorySamples    = 30;       // Minimum valid spread samples

//--- Quote and execution settings
input group "Quote and execution"
input int  InpQuoteMaxAgeSeconds = 10;      // Maximum usable quote age in seconds
input int  InpMaxDeviationPoints = 20;      // Requested order deviation in points
input long InpMagicNumber        = 202610;  // Positive identifier for this EA's trades

//--- Panel position
input group "Panel position"
input int                 InpPanelX                   = 15;       // Panel distance from the left
input int                 InpPanelY                   = 145;      // Panel distance from the top

//--- Symbol properties and runtime state
double g_point       = 0.0;   // Price size of one point for the chart symbol
double g_volumeMin   = 0.0;   // Smallest permitted trade volume
double g_volumeMax   = 0.0;   // Largest permitted trade volume
double g_volumeStep  = 0.0;   // Permitted volume increment
bool   g_timerActive = false; // Whether the timer started successfully

//--- Current quote state
double   g_bid          = 0.0;   // Bid from the last valid quote
double   g_ask          = 0.0;   // Ask from the last valid quote
double   g_spreadPoints = 0.0;   // Current Bid/Ask spread in points
datetime g_quoteTime    = 0;     // Server time of the latest symbol quote
bool     g_quoteValid   = false; // Whether the quote is usable
string   g_quoteStatus  = "WAITING FOR QUOTE"; // Current quote availability

//--- Historical spread settings and state
#define HISTORY_TICK_LIMIT       20000
#define HISTORY_REFRESH_SECONDS  60

double   g_historicalSpreadPoints = 0.0;       // Selected historical spread in points
int      g_historySampleCount     = 0;         // Valid one-second spread samples
bool     g_historyAvailable       = false;     // Whether the percentile is supported
datetime g_lastHistoryAttempt     = 0;         // Time of the latest history request
string   g_historyStatus          = "WAITING"; // History availability and coverage

datetime g_historyFirstSampleTime = 0;         // First valid sample, server time
datetime g_historyLastSampleTime  = 0;         // Last valid sample, server time
long     g_historySpanSeconds     = 0;         // Time between first and last samples
bool     g_historyTickLimitHit    = false;     // Tick cap prevented full requested retrieval

//--- Planned-move calculation state
double g_currentResultPoints = 0.0;   // Pre-trade estimate with current spread at exit
double g_stressResultPoints  = 0.0;   // Pre-trade estimate using max(live spread, percentile)
double g_stressSpreadPoints  = 0.0;   // Exit spread used by the stress scenario
bool   g_currentResultValid  = false; // Whether the current scenario is usable
bool   g_stressResultValid   = false; // Whether the stress scenario is usable

//--- Dashboard state
#define PANEL_ROW_COUNT 18
string g_panelPrefix    = "";    // Names owned by this EA on this chart
bool   g_panelCollapsed = false; // Whether only the header is visible

//--- Manual execution state
CTrade   g_trade;
bool     g_requestPending = false;           // A button request is being processed
bool     g_tradeLocked    = false;           // A fill or uncertain outcome prevents another request
bool     g_fillConfirmed  = false;           // A confirmed fill awaits position closure
datetime g_fillTime       = 0;               // Time of the confirmed fill
string   g_tradeStatus    = "No order sent"; // Latest execution outcome

//--- Execution-attempt reconciliation state
uint            g_attemptRequestId  = 0;              // Terminal-assigned request identifier
ulong           g_attemptOrder      = 0;              // Exact originating order ticket
ulong           g_attemptDeal       = 0;              // Returned or reconciled execution deal
ulong           g_attemptPositionId = 0;              // Position identifier established by deals
datetime        g_attemptTime       = 0;              // Server time before submission
double          g_attemptVolume     = 0.0;            // Requested volume retained for comparison
ENUM_ORDER_TYPE g_attemptType       = ORDER_TYPE_BUY; // Requested direction
string          g_attemptComment    = "";             // Attempt token for matching request events
string          g_reconciliationStatus = "No pending reconciliation"; // Current lock explanation

//+------------------------------------------------------------------+
//| Validate the configured inputs                                   |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpDirection != PLAN_BUY && InpDirection != PLAN_SELL)
     {
      Print("Trading Cost Planner: Invalid trade direction.");
      return(false);
     }

   if(!MathIsValidNumber(InpVolume) || InpVolume <= 0.0)
     {
      Print("Trading Cost Planner: Trade volume must be greater than zero.");
      return(false);
     }

   if(!MathIsValidNumber(InpTargetMovePoints) || InpTargetMovePoints <= 0.0)
     {
      Print("Trading Cost Planner: Expected move must be greater than zero points.");
      return(false);
     }

   if(!MathIsValidNumber(InpMinimumAfterSpreadPoints) ||
      InpMinimumAfterSpreadPoints < 0.0)
     {
      Print("Trading Cost Planner: Minimum result after spread cannot be negative.");
      return(false);
     }

   if(InpHistoryHours < 1 || InpHistoryHours > 168)
     {
      Print("Trading Cost Planner: History interval must be 1 to 168 hours.");
      return(false);
     }

   if(InpStressPercentile <= 50 || InpStressPercentile >= 100)
     {
      Print("Trading Cost Planner: Stress percentile must be between 51 and 99.");
      return(false);
     }

   if(InpMinimumHistorySamples < 1 || InpMinimumHistorySamples > 100000)
     {
      Print("Trading Cost Planner: Minimum history samples must be 1 to 100000.");
      return(false);
     }

   if(InpQuoteMaxAgeSeconds < 1 || InpQuoteMaxAgeSeconds > 3600)
     {
      Print("Trading Cost Planner: Maximum quote age must be 1 to 3600 seconds.");
      return(false);
     }

   if(InpMaxDeviationPoints < 0 || InpPanelX < 0 || InpPanelY < 0)
     {
      Print("Trading Cost Planner: Deviation and panel distances cannot be negative.");
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Validate the identifier assigned to this EA's trade requests      |
//+------------------------------------------------------------------+
bool ValidateMagicNumber()
  {
//--- Reserve zero for trades without this EA's positive identifier.
//--- A signed input also permits a direct check against negative values.
   if(InpMagicNumber <= 0)
     {
      Print("Trading Cost Planner: Magic number must be greater than zero.");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Read and validate the chart symbol's trading properties          |
//+------------------------------------------------------------------+
bool InitializeSymbolProperties()
  {
   ResetLastError();
   if(!SymbolInfoDouble(_Symbol, SYMBOL_POINT, g_point))
     {
      PrintFormat("Trading Cost Planner: Cannot read point size for %s. Error %d.",
                  _Symbol, GetLastError());
      return(false);
     }

   ResetLastError();
   if(!SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, g_volumeMin))
     {
      PrintFormat("Trading Cost Planner: Cannot read minimum volume for %s. Error %d.",
                  _Symbol, GetLastError());
      return(false);
     }

   ResetLastError();
   if(!SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, g_volumeMax))
     {
      PrintFormat("Trading Cost Planner: Cannot read maximum volume for %s. Error %d.",
                  _Symbol, GetLastError());
      return(false);
     }

   ResetLastError();
   if(!SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, g_volumeStep))
     {
      PrintFormat("Trading Cost Planner: Cannot read volume step for %s. Error %d.",
                  _Symbol, GetLastError());
      return(false);
     }

   if(!MathIsValidNumber(g_point) || g_point <= 0.0 ||
      !MathIsValidNumber(g_volumeMin) || g_volumeMin <= 0.0 ||
      !MathIsValidNumber(g_volumeMax) || g_volumeMax < g_volumeMin ||
      !MathIsValidNumber(g_volumeStep) || g_volumeStep <= 0.0)
     {
      PrintFormat("Trading Cost Planner: Invalid trading properties for %s.", _Symbol);
      return(false);
     }

//--- Reject an unsupported lot size instead of changing it silently
   if(InpVolume < g_volumeMin - 1.0e-8 ||
      InpVolume > g_volumeMax + 1.0e-8)
     {
      PrintFormat("Trading Cost Planner: Volume %.8f is outside the permitted range "
                  "%.8f to %.8f lots on %s.",
                  InpVolume, g_volumeMin, g_volumeMax, _Symbol);
      return(false);
     }

   double steps = InpVolume / g_volumeStep;
   if(MathAbs(steps - MathRound(steps)) > 1.0e-7)
     {
      PrintFormat("Trading Cost Planner: Volume %.8f does not match the %.8f-lot "
                  "step on %s.",
                  InpVolume, g_volumeStep, _Symbol);
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Read a fresh Bid/Ask quote for the chart symbol                   |
//+------------------------------------------------------------------+
bool ReadCurrentQuote()
  {
//--- Clear the previous snapshot before attempting another read.
//--- A failed check must not leave old prices marked as current.
   g_quoteValid   = false;
   g_bid          = 0.0;
   g_ask          = 0.0;
   g_spreadPoints = 0.0;
   g_quoteTime    = 0;

//--- Validate the conversion unit before dividing a price difference.
   if(!MathIsValidNumber(g_point) || g_point <= 0.0)
     {
      g_quoteStatus = "INVALID POINT SIZE";
      return(false);
     }

//--- Obtain Bid, Ask, and quote time from one coherent tick snapshot.
   MqlTick tick = {};
   ResetLastError();

   if(!SymbolInfoTick(_Symbol, tick))
     {
      g_quoteStatus = StringFormat("QUOTE UNAVAILABLE: error %d",
                                   GetLastError());
      return(false);
     }

//--- Equal Bid and Ask are permitted. Reject unusable prices,
//--- a reversed quote, or a missing timestamp.
   if(!MathIsValidNumber(tick.bid) ||
      !MathIsValidNumber(tick.ask) ||
      tick.bid <= 0.0 ||
      tick.ask <= 0.0 ||
      tick.ask < tick.bid ||
      tick.time <= 0)
     {
      g_quoteStatus = "INVALID BID/ASK QUOTE";
      return(false);
     }

//--- Use advancing server time so timer updates can detect an old
//--- quote even when the chart symbol receives no new ticks.
   datetime serverTime = TimeTradeServer();

   if(serverTime <= 0)
     {
      g_quoteStatus = "SERVER TIME UNAVAILABLE";
      return(false);
     }

   long quoteAge = (long)(serverTime - tick.time);

   if(quoteAge < 0)
     {
      g_quoteStatus = "QUOTE TIME IS AHEAD OF SERVER TIME";
      return(false);
     }

   if(quoteAge > InpQuoteMaxAgeSeconds)
     {
      g_quoteStatus = StringFormat("STALE QUOTE: %I64d seconds old",
                                   quoteAge);
      return(false);
     }

//--- Express the spread in the symbol's points. Zero is valid,
//--- matching the existing historical-sample and projection policies.
   double spreadPoints = (tick.ask - tick.bid) / g_point;

   if(!MathIsValidNumber(spreadPoints) || spreadPoints < 0.0)
     {
      g_quoteStatus = "INVALID SPREAD";
      return(false);
     }

//--- Publish the snapshot only after all validation succeeds.
   g_bid          = tick.bid;
   g_ask          = tick.ask;
   g_spreadPoints = spreadPoints;
   g_quoteTime    = tick.time;
   g_quoteValid   = true;
   g_quoteStatus  = "CURRENT QUOTE";

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Measure historical spread and record actual sample boundaries    |
//+------------------------------------------------------------------+
bool RefreshHistoricalSpread()
  {
//--- Clear both the percentile and its coverage metadata.
//--- A failed refresh must not leave an old interval looking current.
   g_historyAvailable       = false;
   g_historicalSpreadPoints = 0.0;
   g_historySampleCount     = 0;
   g_historyFirstSampleTime = 0;
   g_historyLastSampleTime  = 0;
   g_historySpanSeconds     = 0;
   g_historyTickLimitHit    = false;

   if(!MathIsValidNumber(g_point) || g_point <= 0.0)
     {
      g_historyStatus = "INVALID POINT SIZE";
      return(false);
     }

   datetime serverTime = TimeTradeServer();

   if(serverTime <= 0)
     {
      g_historyStatus = "SERVER TIME UNAVAILABLE";
      return(false);
     }

   datetime windowStart = serverTime - InpHistoryHours * 3600;
   MqlTick ticks[];

//--- Preserve the existing request: latest information ticks,
//--- capped at HISTORY_TICK_LIMIT.
   ResetLastError();
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_INFO, 0,
                          HISTORY_TICK_LIMIT);
   int copyError = GetLastError();

   if(copied <= 0 || copyError != 0)
     {
      g_historyStatus = StringFormat("TICK HISTORY UNAVAILABLE: error %d",
                                     copyError);
      return(false);
     }

//--- A full response beginning after the requested start indicates
//--- that the tick cap restricted the retrieved interval.
   g_historyTickLimitHit =
      (copied == HISTORY_TICK_LIMIT && ticks[0].time > windowStart);

   double spreads[];

   if(ArrayResize(spreads, copied) != copied)
     {
      g_historyStatus = "CANNOT ALLOCATE SPREAD SAMPLES";
      return(false);
     }

   int      validCount = 0;
   datetime sampleTime = 0;

//--- Preserve one latest valid quote per sampled second.
//--- Seconds without valid ticks do not generate synthetic samples.
   for(int i = 0; i < copied; i++)
     {
      if(ticks[i].time < windowStart || ticks[i].time > serverTime)
         continue;

      if(!MathIsValidNumber(ticks[i].bid) ||
         !MathIsValidNumber(ticks[i].ask) ||
         ticks[i].bid <= 0.0 ||
         ticks[i].ask <= 0.0 ||
         ticks[i].ask < ticks[i].bid)
         continue;

      double spreadPoints = (ticks[i].ask - ticks[i].bid) / g_point;

      if(!MathIsValidNumber(spreadPoints) || spreadPoints < 0.0)
         continue;

//--- Replace the observation within the same second without
//--- increasing the sample count or changing its second timestamp.
      if(validCount > 0 && ticks[i].time == sampleTime)
        {
         spreads[validCount - 1] = spreadPoints;
         continue;
        }

//--- Record boundaries from accepted samples, not merely from
//--- the first and last raw ticks returned by CopyTicks().
      if(validCount == 0)
         g_historyFirstSampleTime = ticks[i].time;

      g_historyLastSampleTime = ticks[i].time;

      spreads[validCount] = spreadPoints;
      validCount++;
      sampleTime = ticks[i].time;
     }

   g_historySampleCount = validCount;

//--- One valid sample has a zero span. No samples leave both
//--- timestamps unset, allowing the display to show unavailable.
   if(validCount > 0)
      g_historySpanSeconds =
         (long)(g_historyLastSampleTime - g_historyFirstSampleTime);

//--- Keep the sample metadata even when the percentile cannot
//--- be supported by the configured minimum count.
   if(validCount < InpMinimumHistorySamples)
     {
      g_historyStatus = StringFormat("INSUFFICIENT HISTORY: %d/%d samples",
                                     validCount, InpMinimumHistorySamples);
      return(false);
     }

   if(ArrayResize(spreads, validCount) != validCount)
     {
      g_historyStatus = "CANNOT RESIZE SPREAD SAMPLES";
      return(false);
     }

   ResetLastError();
   if(!ArraySort(spreads))
     {
      g_historyStatus = StringFormat("CANNOT SORT SPREAD SAMPLES: error %d",
                                     GetLastError());
      return(false);
     }

//--- Preserve the nearest-rank percentile method.
   int rank = (int)MathCeil(validCount *
                           (double)InpStressPercentile / 100.0) - 1;

   g_historicalSpreadPoints = spreads[rank];
   g_historyAvailable       = true;

   if(g_historyTickLimitHit)
      g_historyStatus = "READY: TICK CAP LIMITED RETRIEVAL";
   else
      g_historyStatus = "READY";

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Format a sample span without rounding it to whole hours           |
//+------------------------------------------------------------------+
string FormatHistorySpan(const long seconds)
  {
   long hours   = seconds / 3600;
   long minutes = (seconds % 3600) / 60;
   long rest    = seconds % 60;

   return(StringFormat("%I64dh %I64dm %I64ds", hours, minutes, rest));
  }
  
//+------------------------------------------------------------------+
//| Project the result for an assumed exit spread                    |
//+------------------------------------------------------------------+
bool CalculateProjectedResult(const double exitSpreadPoints,
                              double &resultPoints)
  {
   resultPoints = 0.0;

   if(!g_quoteValid ||
      !MathIsValidNumber(exitSpreadPoints) ||
      exitSpreadPoints < 0.0 ||
      g_point <= 0.0)
      return(false);

   double midpoint      = (g_bid + g_ask) / 2.0;
   double targetDistance = InpTargetMovePoints * g_point;
   double exitSpread     = exitSpreadPoints * g_point;
   double openingPrice   = 0.0;
   double closingPrice   = 0.0;

//--- Use the executable side of each quote for the planned market exit
   if(InpDirection == PLAN_BUY)
     {
      openingPrice = g_ask;
      closingPrice = midpoint + targetDistance - exitSpread / 2.0;
      resultPoints = (closingPrice - openingPrice) / g_point;
     }
   else if(InpDirection == PLAN_SELL)
     {
      openingPrice = g_bid;
      closingPrice = midpoint - targetDistance + exitSpread / 2.0;
      resultPoints = (openingPrice - closingPrice) / g_point;
     }
   else
      return(false);

   return(MathIsValidNumber(closingPrice) &&
          closingPrice > 0.0 &&
          MathIsValidNumber(resultPoints));
  }
  
//+------------------------------------------------------------------+
//| Update the current-spread and historical-scenario estimates      |
//+------------------------------------------------------------------+
void CalculatePlannedMove()
  {
//--- Invalidate previous estimates before evaluating the latest state.
//--- Zero is a possible numeric result, so validity uses separate flags.
   g_currentResultValid  = false;
   g_stressResultValid   = false;
   g_currentResultPoints = 0.0;
   g_stressResultPoints  = 0.0;
   g_stressSpreadPoints  = 0.0;

   if(!g_quoteValid)
      return;

//--- The current-spread estimate assumes that the exit spread equals
//--- the live entry spread, including a valid zero spread.
   g_currentResultValid =
      CalculateProjectedResult(g_spreadPoints, g_currentResultPoints);

//--- Without sufficient history, only the current-spread estimate
//--- can be supported. Do not substitute a fabricated historical value.
   if(!g_historyAvailable)
      return;

//--- Use the greater of the live spread and historical percentile.
//--- When the percentile is no higher than the live spread, both
//--- estimates use the same exit spread and therefore agree.
   g_stressSpreadPoints = MathMax(g_spreadPoints,
                                 g_historicalSpreadPoints);

   g_stressResultValid =
      CalculateProjectedResult(g_stressSpreadPoints,
                               g_stressResultPoints);
  }
  
//+------------------------------------------------------------------+
//| Delete one dashboard object when it exists                      |
//+------------------------------------------------------------------+
bool DeletePanelObject(const string name)
  {
   if(ObjectFind(0, name) < 0)
      return(true);

   ResetLastError();
   if(!ObjectDelete(0, name))
     {
      PrintFormat("Trading Cost Planner: Could not delete %s. Error %d.",
                  name, GetLastError());
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Remove the expanded dashboard body and its controls             |
//+------------------------------------------------------------------+
bool DeletePanelBody()
  {
   bool success = true;

   for(int row = 0; row < PANEL_ROW_COUNT; row++)
     {
      string name = g_panelPrefix + "ROW_" + IntegerToString(row);

      if(!DeletePanelObject(name))
         success = false;
     }

   if(!DeletePanelObject(g_panelPrefix + "EXECUTE"))
      success = false;

   if(!DeletePanelObject(g_panelPrefix + "TRADE_STATUS"))
      success = false;

   return(success);
  }

//+------------------------------------------------------------------+
//| Remove all dashboard objects owned by this EA                    |
//+------------------------------------------------------------------+
void DeletePanel()
  {
   DeletePanelBody();
   DeletePanelObject(g_panelPrefix + "TOGGLE");
   DeletePanelObject(g_panelPrefix + "TITLE");
   DeletePanelObject(g_panelPrefix + "BACKGROUND");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Create a dashboard text label                                    |
//+------------------------------------------------------------------+
bool CreatePanelLabel(const string name,
                      const int x,
                      const int y,
                      const int fontSize,
                      const color textColor,
                      const string text)
  {
   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
     {
      PrintFormat("Trading Cost Planner: Could not create %s. Error %d.",
                  name, GetLastError());
      return(false);
     }

   if(!ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x) ||
      !ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y) ||
      !ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize) ||
      !ObjectSetInteger(0, name, OBJPROP_COLOR, textColor) ||
      !ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false) ||
      !ObjectSetInteger(0, name, OBJPROP_HIDDEN, true) ||
      !ObjectSetString(0, name, OBJPROP_FONT, "Arial") ||
      !ObjectSetString(0, name, OBJPROP_TEXT, text))
     {
      PrintFormat("Trading Cost Planner: Could not configure %s. Error %d.",
                  name, GetLastError());
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Create execution controls below the information rows             |
//+------------------------------------------------------------------+
bool CreateTradeControls()
  {
   string button = g_panelPrefix + "EXECUTE";

//--- Derive positions from the row count so added information rows
//--- cannot overlap the execution button and its status label.
   int buttonY     = InpPanelY + 48 + PANEL_ROW_COUNT * 23 + 7;
   int statusY     = buttonY + 38;
   int panelHeight = statusY - InpPanelY + 27;

   ResetLastError();
   if(!ObjectCreate(0, button, OBJ_BUTTON, 0, 0, 0))
     {
      PrintFormat("Trading Cost Planner: Could not create execution button. Error %d.",
                  GetLastError());
      return(false);
     }

   if(!ObjectSetInteger(0, button, OBJPROP_CORNER, CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0, button, OBJPROP_XDISTANCE, InpPanelX + 14) ||
      !ObjectSetInteger(0, button, OBJPROP_YDISTANCE, buttonY) ||
      !ObjectSetInteger(0, button, OBJPROP_XSIZE, 205) ||
      !ObjectSetInteger(0, button, OBJPROP_YSIZE, 30) ||
      !ObjectSetInteger(0, button, OBJPROP_BGCOLOR, clrForestGreen) ||
      !ObjectSetInteger(0, button, OBJPROP_COLOR, clrWhite) ||
      !ObjectSetInteger(0, button, OBJPROP_SELECTABLE, false) ||
      !ObjectSetInteger(0, button, OBJPROP_HIDDEN, true) ||
      !ObjectSetString(0, button, OBJPROP_TEXT, "EXECUTE AT MARKET"))
     {
      PrintFormat("Trading Cost Planner: Could not configure execution button. Error %d.",
                  GetLastError());
      return(false);
     }

   if(!CreatePanelLabel(g_panelPrefix + "TRADE_STATUS",
                        InpPanelX + 14,
                        statusY,
                        9,
                        clrBlack,
                        g_tradeStatus))
      return(false);

//--- Include all rows and controls inside the white background.
   ResetLastError();
   if(!ObjectSetInteger(0, g_panelPrefix + "BACKGROUND",
                        OBJPROP_YSIZE, panelHeight))
     {
      PrintFormat("Trading Cost Planner: Could not extend panel background. Error %d.",
                  GetLastError());
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Create information rows and manual execution controls            |
//+------------------------------------------------------------------+
bool CreatePanelBody()
  {
//--- Each row has a stable object name. Updating its text does not
//--- require recreating the panel on every quote or timer event.
   for(int row = 0; row < PANEL_ROW_COUNT; row++)
     {
      string name = g_panelPrefix + "ROW_" + IntegerToString(row);

      if(!CreatePanelLabel(name,
                           InpPanelX + 14,
                           InpPanelY + 48 + row * 23,
                           9,
                           clrBlack,
                           ""))
         return(false);
     }

//--- Execution controls calculate their position from the same
//--- row count and extend the background to include the outcome label.
   return(CreateTradeControls());
  }

//+------------------------------------------------------------------+
//| Create the white dashboard and its persistent header            |
//+------------------------------------------------------------------+
bool BuildPanel()
  {
   string background = g_panelPrefix + "BACKGROUND";

   ResetLastError();
   if(!ObjectCreate(0, background, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      PrintFormat("Trading Cost Planner: Could not create panel background. Error %d.",
                  GetLastError());
      return(false);
     }

   if(!ObjectSetInteger(0, background, OBJPROP_CORNER, CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0, background, OBJPROP_XDISTANCE, InpPanelX) ||
      !ObjectSetInteger(0, background, OBJPROP_YDISTANCE, InpPanelY) ||
      !ObjectSetInteger(0, background, OBJPROP_XSIZE, 650) ||
      !ObjectSetInteger(0, background, OBJPROP_YSIZE, 290) ||
      !ObjectSetInteger(0, background, OBJPROP_BGCOLOR, clrWhite) ||
      !ObjectSetInteger(0, background, OBJPROP_BORDER_COLOR, clrSilver) ||
      !ObjectSetInteger(0, background, OBJPROP_BACK, false) ||
      !ObjectSetInteger(0, background, OBJPROP_SELECTABLE, false) ||
      !ObjectSetInteger(0, background, OBJPROP_HIDDEN, true))
     {
      PrintFormat("Trading Cost Planner: Could not configure panel background. Error %d.",
                  GetLastError());
      DeletePanel();
      return(false);
     }

   if(!CreatePanelLabel(g_panelPrefix + "TITLE",
                        InpPanelX + 14,
                        InpPanelY + 11,
                        12,
                        clrBlack,
                        "TRADING COST PLANNER"))
     {
      DeletePanel();
      return(false);
     }

   string toggle = g_panelPrefix + "TOGGLE";

   ResetLastError();
   if(!ObjectCreate(0, toggle, OBJ_BUTTON, 0, 0, 0))
     {
      PrintFormat("Trading Cost Planner: Could not create collapse button. Error %d.",
                  GetLastError());
      DeletePanel();
      return(false);
     }

   if(!ObjectSetInteger(0, toggle, OBJPROP_CORNER, CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0, toggle, OBJPROP_XDISTANCE, InpPanelX + 611) ||
      !ObjectSetInteger(0, toggle, OBJPROP_YDISTANCE, InpPanelY + 7) ||
      !ObjectSetInteger(0, toggle, OBJPROP_XSIZE, 27) ||
      !ObjectSetInteger(0, toggle, OBJPROP_YSIZE, 24) ||
      !ObjectSetInteger(0, toggle, OBJPROP_BGCOLOR, clrWhite) ||
      !ObjectSetInteger(0, toggle, OBJPROP_COLOR, clrBlack) ||
      !ObjectSetInteger(0, toggle, OBJPROP_BORDER_COLOR, clrSilver) ||
      !ObjectSetInteger(0, toggle, OBJPROP_SELECTABLE, false) ||
      !ObjectSetInteger(0, toggle, OBJPROP_HIDDEN, true) ||
      !ObjectSetString(0, toggle, OBJPROP_TEXT, "-"))
     {
      PrintFormat("Trading Cost Planner: Could not configure collapse button. Error %d.",
                  GetLastError());
      DeletePanel();
      return(false);
     }

   if(!CreatePanelBody())
     {
      DeletePanel();
      return(false);
     }

   ChartRedraw();
   return(true);
  }
  
 
//+------------------------------------------------------------------+
//| Update one dashboard row                                         |
//+------------------------------------------------------------------+
bool SetPanelRow(const int row,
                 const string text,
                 const color textColor)
  {
   string name = g_panelPrefix + "ROW_" + IntegerToString(row);

   ResetLastError();
   if(!ObjectSetString(0, name, OBJPROP_TEXT, text) ||
      !ObjectSetInteger(0, name, OBJPROP_COLOR, textColor))
     {
      PrintFormat("Trading Cost Planner: Could not update row %d. Error %d.",
                  row, GetLastError());
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Apply the account-specific existing-position rule                |
//+------------------------------------------------------------------+
bool CheckPositionRule(string &reason)
  {
   reason = "";

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   bool hedging =
      (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

//--- Recognize both netting account modes explicitly. An unknown
//--- mode must not silently inherit a position policy.
   if(!hedging &&
      marginMode != ACCOUNT_MARGIN_MODE_RETAIL_NETTING &&
      marginMode != ACCOUNT_MARGIN_MODE_EXCHANGE)
     {
      reason = "Unsupported account position mode";
      return(false);
     }

   int positionCount = PositionsTotal();

//--- Examine every position because hedging accounts can contain
//--- several positions on the same symbol with different identifiers.
   for(int index = 0; index < positionCount; index++)
     {
      ResetLastError();
      ulong ticket = PositionGetTicket(index);

      if(ticket == 0)
        {
         reason = StringFormat("Cannot read position ticket: error %d",
                               GetLastError());
         return(false);
        }

//--- Reselect by ticket before reading properties. If account state
//--- changes during the scan, stop rather than assume no position exists.
      ResetLastError();

      if(!PositionSelectByTicket(ticket))
        {
         reason = StringFormat("Cannot select position: error %d",
                               GetLastError());
         return(false);
        }

      string symbol = "";

      ResetLastError();

      if(!PositionGetString(POSITION_SYMBOL, symbol))
        {
         reason = StringFormat("Cannot read position symbol: error %d",
                               GetLastError());
         return(false);
        }

      if(symbol != _Symbol)
         continue;

//--- Netting combines exposure on the symbol. Magic number cannot
//--- isolate a new order from an existing combined position.
      if(!hedging)
        {
         reason = "A position exists on this netting symbol";
         return(false);
        }

      long magic = 0;

      ResetLastError();

      if(!PositionGetInteger(POSITION_MAGIC, magic))
        {
         reason = StringFormat("Cannot read position magic: error %d",
                               GetLastError());
         return(false);
        }

//--- On hedging accounts, unrelated positions are permitted.
//--- Only this symbol-and-magic identification group blocks execution.
      if(magic == InpMagicNumber)
        {
         reason = "A matching EA position exists on this symbol";
         return(false);
        }
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Compare estimated order margin with current free margin          |
//+------------------------------------------------------------------+
bool CheckMarginReady(string &reason)
  {
   reason = "";

//--- The caller must provide a validated quote. The execution path
//--- refreshes that quote immediately before running readiness checks.
   if(!g_quoteValid)
     {
      reason = g_quoteStatus;
      return(false);
     }

   ENUM_ORDER_TYPE orderType;
   double openingPrice = 0.0;

   if(InpDirection == PLAN_BUY)
     {
      orderType    = ORDER_TYPE_BUY;
      openingPrice = g_ask;
     }
   else if(InpDirection == PLAN_SELL)
     {
      orderType    = ORDER_TYPE_SELL;
      openingPrice = g_bid;
     }
   else
     {
      reason = "Invalid trade direction";
      return(false);
     }

//--- Calculate standalone margin for the requested volume.
//--- Failure to obtain an estimate blocks the request.
   double requiredMargin = 0.0;

   ResetLastError();

   if(!OrderCalcMargin(orderType, _Symbol, InpVolume,
                       openingPrice, requiredMargin))
     {
      reason = StringFormat("Cannot estimate margin: error %d",
                            GetLastError());
      return(false);
     }

   if(!MathIsValidNumber(requiredMargin) || requiredMargin < 0.0)
     {
      reason = "Invalid estimated margin";
      return(false);
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(!MathIsValidNumber(freeMargin))
     {
      reason = "Invalid account free margin";
      return(false);
     }

//--- This is a preliminary affordability comparison, not a broker
//--- approval. Prices, account state, and margin treatment can change.
   if(freeMargin < requiredMargin)
     {
      reason = StringFormat("Insufficient margin: need %.2f, free %.2f %s",
                            requiredMargin,
                            freeMargin,
                            AccountInfoString(ACCOUNT_CURRENCY));
      return(false);
     }

   return(true);
  }
  
                     
//+------------------------------------------------------------------+
//| Check current prerequisites for a market-order request            |
//+------------------------------------------------------------------+
bool CheckMarketTradeReady(string &reason)
  {
   reason = "";

//--- Keep duplicate-request and unresolved-outcome protection ahead
//--- of all other checks.
   if(g_requestPending)
     {
      reason = "Order request in progress";
      return(false);
     }

   if(g_tradeLocked)
     {
      reason = "Locked: " + g_reconciliationStatus;
      return(false);
     }

   if(!g_quoteValid)
     {
      reason = g_quoteStatus;
      return(false);
     }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      reason = "Terminal is disconnected";
      return(false);
     }

//--- All relevant terminal, program, and account permissions
//--- must permit an Expert Advisor trade request.
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      reason = "EA trading is not permitted";
      return(false);
     }

   if(InpMagicNumber <= 0)
     {
      reason = "Invalid EA magic number";
      return(false);
     }

//--- Reuse the existing range and volume-step validation.
//--- Reject unsupported volume without silently rounding the order.
   if(!InitializeSymbolProperties())
     {
      reason = "Invalid volume or symbol properties; see Experts";
      return(false);
     }

//--- Use the same account-specific position rule for display,
//--- click-time permission, and confirmed-fill lock reconciliation.
   if(!CheckPositionRule(reason))
      return(false);

   long tradeMode = 0;
   long orderMode = 0;

   ResetLastError();

   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE, tradeMode) ||
      !SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE, orderMode))
     {
      reason = StringFormat("Cannot read symbol trading rules: error %d",
                            GetLastError());
      return(false);
     }

   if((orderMode & SYMBOL_ORDER_MARKET) == 0)
     {
      reason = "Market orders are not allowed on this symbol";
      return(false);
     }

   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED ||
      tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (InpDirection == PLAN_BUY &&
       tradeMode == SYMBOL_TRADE_MODE_SHORTONLY) ||
      (InpDirection == PLAN_SELL &&
       tradeMode == SYMBOL_TRADE_MODE_LONGONLY))
     {
      reason = "Selected direction is not allowed on this symbol";
      return(false);
     }

//--- Estimate affordability only after volume and symbol rules
//--- have passed. The advisory point threshold is not checked here.
   if(!CheckMarginReady(reason))
      return(false);

   return(true);
  }
  
 
//+------------------------------------------------------------------+
//| Identify responses that establish a failed market request        |
//+------------------------------------------------------------------+
bool IsDefiniteRequestFailure(const uint retcode)
  {
//--- Use an explicit list. An unknown or missing response must not
//--- unlock a request merely because it is not a successful retcode.
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_CANCEL:
      case TRADE_RETCODE_INVALID:
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_INVALID_PRICE:
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_INVALID_EXPIRATION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
      case TRADE_RETCODE_SERVER_DISABLES_AT:
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_LIMIT_ORDERS:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_INVALID_ORDER:
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Submit one manual request and retain its reconciliation identity |
//+------------------------------------------------------------------+
void ExecuteMarketOrder()
  {
   ReadCurrentQuote();
   CalculatePlannedMove();
   string reason = "";
   if(!CheckMarketTradeReady(reason))
     {
      PrintFormat("Trading Cost Planner: Order blocked: %s.", reason);
      UpdatePanel();
      return;
     }
   g_requestPending = true;
   UpdatePanel();
   ResetLastError();
   if(!g_trade.SetTypeFillingBySymbol(_Symbol))
     {
      PrintFormat("Trading Cost Planner: Unsupported filling policy. Error %d.",
                  GetLastError());
      g_requestPending = false;
      UpdatePanel();
      return;
     }

//--- Retain the attempt before submission. Lock first so any unclear
//--- response cannot enable another click. Comment matching is used
//--- only for request events when a request ID was not returned.
   g_attemptTime = TimeTradeServer();
   g_attemptVolume = InpVolume;
   g_attemptType = (InpDirection == PLAN_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   g_attemptComment = StringFormat("TCP_%I64u", GetMicrosecondCount());
   g_attemptRequestId = 0;
   g_attemptOrder = 0;
   g_attemptDeal = 0;
   g_attemptPositionId = 0;
   g_fillConfirmed = false;
   g_fillTime = 0;
   g_tradeLocked = true;
   g_reconciliationStatus = "Awaiting broker outcome";
   g_tradeStatus = "Sending market order...";
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetAsyncMode(false);
   g_trade.SetDeviationInPoints((ulong)InpMaxDeviationPoints);
   UpdatePanel();

//--- Only this click path sends an order. Price zero requests market
//--- execution; SL and TP remain zero. No retry is performed.
   ResetLastError();
   bool sent = (InpDirection == PLAN_BUY ?
                g_trade.Buy(InpVolume, _Symbol, 0.0, 0.0, 0.0, g_attemptComment) :
                g_trade.Sell(InpVolume, _Symbol, 0.0, 0.0, 0.0, g_attemptComment));
   int localError = GetLastError();
   MqlTradeResult result = {};
   g_trade.Result(result);
   g_attemptRequestId = result.request_id;
   g_attemptOrder = result.order;
   g_attemptDeal = result.deal;
   g_requestPending = false;

   if(result.deal > 0 || result.order > 0 ||
      !IsDefiniteRequestFailure(result.retcode))
     {
      g_tradeStatus = StringFormat("AWAITING RECONCILIATION: retcode %u; request %u",
                                  result.retcode, result.request_id);
      RefreshTradeLock();
     }
   else
     {
//--- A definite failure without execution identifiers establishes
//--- rejection of this attempt. Unknown codes stay locked instead.
      g_tradeLocked = false;
      g_tradeStatus = StringFormat("REJECTED: %s (retcode %u)",
                                  g_trade.ResultRetcodeDescription(), result.retcode);
      g_reconciliationStatus = "Definite request failure";
     }
   PrintFormat("Trading Cost Planner: sent=%s, request=%u, order=%I64u, "
               "deal=%I64u, retcode=%u, local error=%d, magic=%I64d. SL=0, TP=0.",
               sent ? "true" : "false", result.request_id, result.order,
               result.deal, result.retcode, localError, InpMagicNumber);
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Reconcile the retained attempt without sending another request   |
//+------------------------------------------------------------------+
void RefreshTradeLock()
  {
   if(!g_tradeLocked || g_requestPending)
      return;

//--- Disconnection or unavailable server time cannot prove closure
//--- or failure. Preserve the lock until broker records can be read.
   datetime now = TimeTradeServer();
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || now <= 0)
     {
      g_reconciliationStatus = "Waiting for connection and server time";
      return;
     }

//--- A returned deal can supply its exact originating order ticket.
//--- Never match an attempt merely by the absence of a position.
   if(g_attemptOrder == 0 && g_attemptDeal > 0)
     {
      long order = 0;
      if(HistoryDealSelect(g_attemptDeal) &&
         HistoryDealGetInteger(g_attemptDeal, DEAL_ORDER, order) && order > 0)
         g_attemptOrder = (ulong)order;
     }

   if(g_attemptOrder == 0)
     {
      g_reconciliationStatus = "No matching order ticket yet; request stays locked";
      return;
     }

//--- A still-active order can execute further, including a remainder
//--- after partial execution. Do not permit another request.
   if(OrderSelect(g_attemptOrder))
     {
      g_reconciliationStatus = "Matching order is active; request stays locked";
      return;
     }

//--- Select broker history from just before this attempt. Failure
//--- or missing history is an unavailable state, not proof of rejection.
   ResetLastError();
   if(!HistorySelect(g_attemptTime - 1, now))
     {
      g_reconciliationStatus = StringFormat("History unavailable: error %d",
                                            GetLastError());
      return;
     }

   long orderMagic = 0;
   long orderType = 0;
   long orderState = 0;
   string orderSymbol = "";
   double initialVolume = 0.0;
   double remainingVolume = 0.0;

//--- Validate identity and final volume using checked property reads.
//--- The order ticket is the primary association; magic and symbol
//--- prevent adopting an unrelated record.
   if(!HistoryOrderGetInteger(g_attemptOrder, ORDER_MAGIC, orderMagic) ||
      !HistoryOrderGetInteger(g_attemptOrder, ORDER_TYPE, orderType) ||
      !HistoryOrderGetInteger(g_attemptOrder, ORDER_STATE, orderState) ||
      !HistoryOrderGetString(g_attemptOrder, ORDER_SYMBOL, orderSymbol) ||
      !HistoryOrderGetDouble(g_attemptOrder, ORDER_VOLUME_INITIAL, initialVolume) ||
      !HistoryOrderGetDouble(g_attemptOrder, ORDER_VOLUME_CURRENT, remainingVolume))
     {
      g_reconciliationStatus = "Matching order history is incomplete; lock retained";
      return;
     }

   if(orderMagic != InpMagicNumber || orderSymbol != _Symbol ||
      orderType != (long)g_attemptType ||
      !MathIsValidNumber(initialVolume) || initialVolume <= 0.0 ||
      !MathIsValidNumber(remainingVolume) || remainingVolume < 0.0 ||
      remainingVolume > initialVolume)
     {
      g_reconciliationStatus = "Order identity or volume is inconsistent; lock retained";
      return;
     }

   bool terminalState =
      (orderState == ORDER_STATE_FILLED || orderState == ORDER_STATE_CANCELED ||
       orderState == ORDER_STATE_REJECTED || orderState == ORDER_STATE_EXPIRED);
   if(!terminalState)
     {
      g_reconciliationStatus = "Order outcome is not final; lock retained";
      return;
     }

//--- Aggregate the exact order's execution deals. Multiple deals
//--- produce total filled volume and a volume-weighted entry price.
   double volume = 0.0;
   double priceVolume = 0.0;
   ulong lastDeal = 0;
   ulong positionId = 0;
   int dealCount = HistoryDealsTotal();
   for(int index = 0; index < dealCount; index++)
     {
      ulong ticket = HistoryDealGetTicket(index);
      long dealOrder = 0;
      if(ticket == 0 || !HistoryDealGetInteger(ticket, DEAL_ORDER, dealOrder))
        {
         g_reconciliationStatus = "Deal history read failed; lock retained";
         return;
        }
      if((ulong)dealOrder != g_attemptOrder)
         continue;

      long dealType = 0;
      if(!HistoryDealGetInteger(ticket, DEAL_TYPE, dealType))
         return;
//--- Ignore non-price deal records such as separate charges.
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         continue;
      long magic = 0;
      long id = 0;
      string symbol = "";
      double lots = 0.0;
      double price = 0.0;
      if(!HistoryDealGetInteger(ticket, DEAL_MAGIC, magic) ||
         !HistoryDealGetInteger(ticket, DEAL_POSITION_ID, id) ||
         !HistoryDealGetString(ticket, DEAL_SYMBOL, symbol) ||
         !HistoryDealGetDouble(ticket, DEAL_VOLUME, lots) ||
         !HistoryDealGetDouble(ticket, DEAL_PRICE, price) ||
         magic != InpMagicNumber || symbol != _Symbol || id <= 0 ||
         dealType != (g_attemptType == ORDER_TYPE_BUY ? DEAL_TYPE_BUY : DEAL_TYPE_SELL) ||
         !MathIsValidNumber(lots) || lots <= 0.0 ||
         !MathIsValidNumber(price) || price <= 0.0)
        {
         g_reconciliationStatus = "Matching deal data is incomplete; lock retained";
         return;
        }
      if(positionId != 0 && positionId != (ulong)id)
        {
         g_reconciliationStatus = "Multiple position identifiers; lock retained";
         return;
        }
      positionId = (ulong)id;
      volume += lots;
      priceVolume += lots * price;
      lastDeal = ticket;
     }

//--- Require consistent final order and deal volumes. This prevents
//--- early unlocking while a partial set of execution records arrives.
   double tolerance = MathMax(1.0e-8, g_volumeStep * 1.0e-6);
   double executedVolume = initialVolume - remainingVolume;
   if(orderState == ORDER_STATE_FILLED)
      executedVolume = initialVolume;
   if(MathAbs(initialVolume - g_attemptVolume) > tolerance ||
      MathAbs(volume - executedVolume) > tolerance)
     {
      g_reconciliationStatus = "Waiting for consistent final order and deal volumes";
      return;
     }

   if(volume <= 0.0)
     {
//--- Only a final non-filled order with unchanged volume and no
//--- execution deals establishes that this order did not execute.
      if(orderState == ORDER_STATE_FILLED || g_fillConfirmed)
         return;
      g_tradeStatus = StringFormat("NOT FILLED: order %I64u; state %s",
                                  g_attemptOrder,
                                  EnumToString((ENUM_ORDER_STATE)orderState));
      g_tradeLocked = false;
      g_reconciliationStatus = "Final no-fill outcome confirmed";
      return;
     }

//--- Broker history confirms execution. Preserve its outcome even
//--- after closure and retain the originating position identifier.
   g_fillConfirmed = true;
   g_attemptPositionId = positionId;
   g_attemptDeal = lastDeal;
   if(g_fillTime == 0)
      g_fillTime = now;
   g_tradeStatus = StringFormat("%s: %.8g lots at %.*f; order %I64u",
                               volume < initialVolume - tolerance ? "PARTIAL FILL" : "FILLED",
                               volume, _Digits, priceVolume / volume, g_attemptOrder);
   if(now <= g_fillTime + 5)
     {
      g_reconciliationStatus = "Confirmed execution; waiting for account settlement";
      return;
     }

//--- Keep the lock while the exact position identifier exists, even
//--- if another operation has changed its magic or netting attributes.
   int positionCount = PositionsTotal();
   for(int index = 0; index < positionCount; index++)
     {
      ulong ticket = PositionGetTicket(index);
      long id = 0;
      if(ticket == 0 || !PositionSelectByTicket(ticket) ||
         !PositionGetInteger(POSITION_IDENTIFIER, id))
        {
         g_reconciliationStatus = "Position scan failed; lock retained";
         return;
        }
      if((ulong)id == g_attemptPositionId)
        {
         g_reconciliationStatus = "Confirmed position remains open";
         return;
        }
     }

   string reason = "";
   if(!CheckPositionRule(reason))
     {
      g_reconciliationStatus = reason;
      return;
     }
   g_tradeLocked = false;
   g_reconciliationStatus = "Execution reconciled; position no longer present";
  }
  
  
//+------------------------------------------------------------------+
//| Display pre-trade estimates, readiness, and the latest outcome    |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
//--- Collapsing removes the body objects. Continue updating runtime
//--- state elsewhere, but do not write to rows that are not present.
   if(g_panelCollapsed)
      return;

   string direction = (InpDirection == PLAN_BUY ? "BUY" : "SELL");

//--- Start with unavailable text. Publish numeric quote values only
//--- when the latest snapshot passed all quote validation checks.
   string quoteText  = "Bid/Ask: unavailable";
   string spreadText = "Current spread: unavailable";

   if(g_quoteValid)
     {
      quoteText = "Bid " + DoubleToString(g_bid, _Digits) +
                  "  |  Ask " + DoubleToString(g_ask, _Digits);

      spreadText = "Current spread: " +
                   DoubleToString(g_spreadPoints, 1) + " points";
     }

//--- Preserve the sample count even when there are too few samples
//--- to support the configured historical percentile.
   string historyText = "Historical spread: unavailable  |  " +
                        IntegerToString(g_historySampleCount) + " samples";

   if(g_historyAvailable)
      historyText = "Historical P" +
                    IntegerToString(InpStressPercentile) + ": " +
                    DoubleToString(g_historicalSpreadPoints, 1) +
                    " points  |  " +
                    IntegerToString(g_historySampleCount) + " samples";

//--- Numeric estimates and advisory comparisons use separate rows.
//--- An unavailable estimate must not receive a threshold verdict.
   string currentText   = "Current-spread estimate: unavailable";
   string stressText    = "Historical-scenario estimate: unavailable";
   string currentStatus = "Current-spread comparison: unavailable";
   string stressStatus  = "Historical-scenario comparison: unavailable";

   color currentColor = clrDimGray;
   color stressColor  = clrDimGray;

   if(g_currentResultValid)
     {
      bool aboveThreshold =
         (g_currentResultPoints >= InpMinimumAfterSpreadPoints);

      currentText = StringFormat("Current-spread estimate: %.1f points",
                                 g_currentResultPoints);

      currentStatus = "Current-spread comparison: " +
                      (aboveThreshold ?
                       "AT OR ABOVE THRESHOLD" : "BELOW THRESHOLD");

      currentColor = (aboveThreshold ? clrForestGreen : clrFireBrick);
     }

   if(g_stressResultValid)
     {
      bool aboveThreshold =
         (g_stressResultPoints >= InpMinimumAfterSpreadPoints);

      stressText = StringFormat("Historical-scenario estimate: %.1f points",
                                g_stressResultPoints);

      stressStatus = "Historical-scenario comparison: " +
                     (aboveThreshold ?
                      "AT OR ABOVE THRESHOLD" : "BELOW THRESHOLD");

      stressColor = (aboveThreshold ? clrForestGreen : clrFireBrick);
     }

//--- Sample boundaries describe accepted observations. They do not
//--- imply uninterrupted tick coverage between those timestamps.
   string firstText = "First sample: unavailable";
   string lastText  = "Last sample: unavailable";
   string spanText  = StringFormat("Requested: %d h  |  Sample span: unavailable",
                                  InpHistoryHours);

   if(g_historySampleCount > 0)
     {
      firstText = "First sample: " +
                  TimeToString(g_historyFirstSampleTime,
                               TIME_DATE | TIME_SECONDS) + " (server)";

      lastText = "Last sample: " +
                 TimeToString(g_historyLastSampleTime,
                              TIME_DATE | TIME_SECONDS) + " (server)";

      spanText = StringFormat("Requested: %d h  |  Sample span: %s",
                              InpHistoryHours,
                              FormatHistorySpan(g_historySpanSeconds));
     }

   string historyStatusText = "History: " + g_historyStatus;

   if(g_historyTickLimitHit && !g_historyAvailable)
      historyStatusText += "  |  TICK CAP";

//--- Readiness is independent of the advisory threshold.
//--- This check reports current prerequisites; it does not guarantee
//--- that a later request will be accepted by the broker.
   string reason = "";
   bool ready = CheckMarketTradeReady(reason);

   string readinessText = "Execution ready: click to request an order";

   if(!ready)
      readinessText = "Execution blocked: " + reason;

//--- Keep readiness separate from g_tradeStatus. A changing quote,
//--- permission, or position must not erase the latest broker outcome.
   if(!SetPanelRow(0,
                   StringFormat("Order size: %s %.8g lots", direction, InpVolume),
                   clrBlack) ||
      !SetPanelRow(1,
                   StringFormat("Expected midpoint move: %.1f points",
                                InpTargetMovePoints),
                   clrBlack) ||
      !SetPanelRow(2, quoteText, clrBlack) ||
      !SetPanelRow(3, "Quote: " + g_quoteStatus,
                   g_quoteValid ? clrForestGreen : clrFireBrick) ||
      !SetPanelRow(4, spreadText, clrBlack) ||
      !SetPanelRow(5, historyText, clrBlack) ||
      !SetPanelRow(6, historyStatusText,
                   g_historyAvailable ? clrForestGreen : clrFireBrick) ||
      !SetPanelRow(7, currentText, currentColor) ||
      !SetPanelRow(8, stressText, stressColor) ||
      !SetPanelRow(9, "SL: none  |  TP: none", clrFireBrick) ||
      !SetPanelRow(10, firstText, clrBlack) ||
      !SetPanelRow(11, lastText, clrBlack) ||
      !SetPanelRow(12, spanText, clrBlack) ||
      !SetPanelRow(13,
                   StringFormat("Advisory threshold: %.1f points",
                                InpMinimumAfterSpreadPoints),
                   clrBlack) ||
      !SetPanelRow(14, currentStatus, currentColor) ||
      !SetPanelRow(15, stressStatus, stressColor) ||
      !SetPanelRow(16, "Pre-trade spread-only estimates in points",
                   clrDimGray) ||
      !SetPanelRow(17, readinessText,
                   ready ? clrForestGreen : clrFireBrick))
      return;

//--- Button color and the readiness row use the same check.
//--- A gray button remains clickable, but execution rechecks the
//--- prerequisites and refuses to send when they are not satisfied.
   string button = g_panelPrefix + "EXECUTE";
   string buttonText = StringFormat("%s %.8g LOTS AT MARKET",
                                    direction, InpVolume);

   ResetLastError();

   if(!ObjectSetString(0, button, OBJPROP_TEXT, buttonText) ||
      !ObjectSetInteger(0, button, OBJPROP_BGCOLOR,
                        ready ? clrForestGreen : clrGray) ||
      !ObjectSetString(0, g_panelPrefix + "TRADE_STATUS",
                       OBJPROP_TEXT, "Last execution: " + g_tradeStatus))
     {
      PrintFormat("Trading Cost Planner: Could not refresh trade controls. Error %d.",
                  GetLastError());
      return;
     }

   ChartRedraw();
  }
  
//+------------------------------------------------------------------+
//| Collapse or expand the dashboard body                            |
//+------------------------------------------------------------------+
bool SetPanelCollapsed(const bool collapsed)
  {
   if(collapsed == g_panelCollapsed)
      return(true);

   string background = g_panelPrefix + "BACKGROUND";
   string toggle     = g_panelPrefix + "TOGGLE";

   if(collapsed)
     {
//--- Delete information rows and trade controls while preserving
//--- the header objects needed to expand the panel again.
      if(!DeletePanelBody())
         return(false);

      if(!ObjectSetInteger(0, background, OBJPROP_YSIZE, 38) ||
         !ObjectSetString(0, toggle, OBJPROP_TEXT, "+"))
        {
         Print("Trading Cost Planner: Could not collapse the panel.");
         return(false);
        }

      g_panelCollapsed = true;
     }
   else
     {
      if(!CreatePanelBody())
        {
         DeletePanelBody();
         return(false);
        }

//--- Use the same layout calculation as CreateTradeControls().
      int panelHeight = 48 + PANEL_ROW_COUNT * 23 + 7 + 38 + 27;

      if(!ObjectSetInteger(0, background, OBJPROP_YSIZE, panelHeight) ||
         !ObjectSetString(0, toggle, OBJPROP_TEXT, "-"))
        {
         Print("Trading Cost Planner: Could not expand the panel.");
         DeletePanelBody();
         return(false);
        }

      g_panelCollapsed = false;
      UpdatePanel();
     }

   ChartRedraw();
   return(true);
  }
  
//+------------------------------------------------------------------+
//| Refresh the quote, projections, and dashboard                    |
//+------------------------------------------------------------------+
void UpdateQuoteReadout()
  {
   ReadCurrentQuote();
   CalculatePlannedMove();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Reject invalid configuration before creating chart objects
//--- or enabling periodic updates.
   if(!ValidateInputs() ||
      !ValidateMagicNumber() ||
      !InitializeSymbolProperties())
      return(INIT_PARAMETERS_INCORRECT);

//--- Configure the request identifier before any click can submit
//--- a trade. This setter does not return a success flag.
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);

   g_panelPrefix    = StringFormat("TCP_%I64d_", ChartID());
   g_panelCollapsed = false;

   if(!BuildPanel())
      return(INIT_FAILED);

   ResetLastError();

   if(!EventSetTimer(5))
     {
      PrintFormat("Trading Cost Planner: Could not start the timer. Error %d.",
                  GetLastError());
      DeletePanel();
      return(INIT_FAILED);
     }

   g_timerActive = true;
   Comment("");
   UpdateQuoteReadout();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Stop updates and remove this EA's panel objects
   if(g_timerActive)
     {
      EventKillTimer();
      g_timerActive = false;
     }

   DeletePanel();
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Refresh promptly when the chart symbol receives a tick
   UpdateQuoteReadout();
  }
  
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   datetime serverTime = TimeTradeServer();

//--- Refresh tick history at most once per minute, including failed attempts
   if(serverTime > 0 &&
      (g_lastHistoryAttempt == 0 ||
       serverTime - g_lastHistoryAttempt >= HISTORY_REFRESH_SECONDS))
     {
      g_lastHistoryAttempt = serverTime;
      RefreshHistoricalSpread();
     }

//--- Reconcile a confirmed fill before refreshing button availability
   RefreshTradeLock();
   UpdateQuoteReadout();
  }
  
//+------------------------------------------------------------------+
//| Handle dashboard button clicks                                   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam != g_panelPrefix + "TOGGLE" &&
      sparam != g_panelPrefix + "EXECUTE")
      return;

//--- Release the clicked button
   ResetLastError();
   if(!ObjectSetInteger(0, sparam, OBJPROP_STATE, false))
     {
      PrintFormat("Trading Cost Planner: Could not release panel button. Error %d.",
                  GetLastError());
      return;
     }

   if(sparam == g_panelPrefix + "TOGGLE")
     {
      SetPanelCollapsed(!g_panelCollapsed);
      return;
     }

//--- Execute only from the expanded dashboard
   if(!g_panelCollapsed)
      ExecuteMarketOrder();
  }

//+------------------------------------------------------------------+
//| Associate a broker request response with the retained attempt    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
//--- Request and result structures are meaningful for REQUEST events.
//--- Other transactions are reconciled by the existing timer.
   if(trans.type != TRADE_TRANSACTION_REQUEST || !g_tradeLocked ||
      g_requestPending)
      return;
   bool matched = (g_attemptRequestId > 0 &&
                   result.request_id == g_attemptRequestId);
   if(g_attemptRequestId == 0)
      matched = (request.action == TRADE_ACTION_DEAL &&
                 request.symbol == _Symbol &&
                 request.magic == (ulong)InpMagicNumber &&
                 request.comment == g_attemptComment &&
                 request.type == g_attemptType &&
                 MathAbs(request.volume - g_attemptVolume) <= 1.0e-8);
   if(!matched)
      return;
   if(result.request_id > 0)
      g_attemptRequestId = result.request_id;
   if(result.order > 0)
      g_attemptOrder = result.order;
   if(result.deal > 0)
      g_attemptDeal = result.deal;
   if(IsDefiniteRequestFailure(result.retcode) &&
      g_attemptOrder == 0 && g_attemptDeal == 0 && !g_fillConfirmed)
     {
      g_tradeLocked = false;
      g_tradeStatus = StringFormat("REJECTED: broker retcode %u", result.retcode);
      g_reconciliationStatus = "Matched request failure confirmed";
     }
//--- No trading or account-close operation is performed here.
//--- The timer reads order/deal history after this short association.
  }

//+------------------------------------------------------------------+
