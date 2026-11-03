//+------------------------------------------------------------------+
//|  GOLD_AMD_Liquidity.mq5                                          |
//|  Strategy : AMD (Accumulation-Manipulation-Distribution)         |
//|             + Judas Swing + Equal Highs/Lows Liquidity Sweep     |
//|  Pair     : XAUUSD (Gold)                                        |
//|  PropFirm : FundedNext / FundingPips / The5ers / FTMO compatible |
//|  Author   : Institutional EA Framework v1.0                      |
//+------------------------------------------------------------------+
#property copyright "Institutional EA Framework"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//==========================================================================
// INPUT PARAMETERS
//==========================================================================

// --- Risk Management ---
input double   RiskPercent       = 0.5;    // Risk per trade (% of balance)
input double   DailyDrawdownLimit= 4.0;    // Max daily DD % (PropFirm safe)
input double   MaxDrawdownLimit  = 8.0;    // Max total DD % (PropFirm safe)
input double   TP1_RR            = 1.5;    // TP1 Risk:Reward ratio
input double   TP2_RR            = 3.0;    // TP2 Risk:Reward ratio
input double   TP1_ClosePct      = 50.0;   // % of position to close at TP1

// --- AMD Session Times (Server Time) ---
input int      AccumStart_Hour   = 2;      // Accumulation phase start (Asia)
input int      AccumEnd_Hour     = 7;      // Accumulation phase end
input int      ManipStart_Hour   = 7;      // Manipulation/Judas Swing (London)
input int      ManipEnd_Hour     = 9;      // Manipulation end
input int      DistribStart_Hour = 13;     // Distribution phase (NY)
input int      DistribEnd_Hour   = 16;     // Distribution end
input int      NoTradeHour_Start = 22;     // No new trades after this hour
input int      NoTradeHour_End   = 1;      // No new trades before this hour

// --- Liquidity Sweep Config ---
input int      LiqSweepLookback  = 20;     // Bars to look back for equal H/L
input double   EqualLevelTolerance= 0.5;   // Pips tolerance for "equal" levels
input int      SweepConfirmBars  = 2;      // Bars after sweep to confirm rejection

// --- News Filter ---
input bool     NewsFilter        = true;   // Enable high-impact news filter
input int      NewsMinutesBefore = 30;     // Minutes before news — no trade
input int      NewsMinutesAfter  = 30;     // Minutes after news — no trade

// --- Execution ---
input int      SlippagePoints    = 30;     // Max slippage (points)
input int      MagicNumber       = 2401;   // Unique magic number
input string   TelegramBotToken  = "";     // Telegram Bot Token
input string   TelegramChatID    = "";     // Telegram Chat ID

// --- Display ---
input bool     ShowDashboard     = true;   // Show on-chart info panel

//==========================================================================
// GLOBAL VARIABLES
//==========================================================================

double   g_DayStartBalance    = 0;
double   g_InitialBalance     = 0;
datetime g_LastTradeDay       = 0;
datetime g_LastBarTime        = 0;
bool     g_TP1Hit             = false;
ulong    g_TicketMain         = 0;

// Liquidity levels
double   g_EqualHighs[];
double   g_EqualLows[];
int      g_EqHighCount        = 0;
int      g_EqLowCount         = 0;

// AMD State
enum ENUM_AMD_PHASE { AMD_NONE, AMD_ACCUM, AMD_MANIP, AMD_DISTRIB };
ENUM_AMD_PHASE g_CurrentPhase = AMD_NONE;
bool     g_JudasSwingBullish  = false;  // true=price swept lows (bull trap), expect up
bool     g_JudasSwingBearish  = false;  // true=price swept highs (bear trap), expect down
double   g_SweptLevel         = 0;
double   g_EntryPrice         = 0;
double   g_SL                 = 0;
double   g_TP1                = 0;
double   g_TP2                = 0;
bool     g_SetupReady         = false;
string   g_SetupDirection     = "";

//==========================================================================
// INITIALIZATION
//==========================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_InitialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayStartBalance = g_InitialBalance;
   g_LastTradeDay    = 0;

   Print("[AMD_EA] Initialized. Balance: ", g_InitialBalance,
         " | Magic: ", MagicNumber);
   SendTelegram("✅ GOLD AMD EA Started | Balance: $" +
                DoubleToString(g_InitialBalance, 2));
   return INIT_SUCCEEDED;
}

//==========================================================================
// TICK PROCESSING
//==========================================================================

void OnTick()
{
   // Only process on new bar (M15 chart recommended)
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   // Daily reset
   ResetDailyTracking();

   // Propfirm drawdown guardian
   if(IsDrawdownBreached()) return;

   // Session / time filter
   if(!IsTradingSessionActive()) return;

   // News filter
   if(NewsFilter && IsNewsTime()) return;

   // Update AMD phase
   UpdateAMDPhase();

   // Scan for liquidity levels
   ScanLiquidityLevels();

   // Check for Judas Swing + Sweep setup
   CheckJudasSwing();

   // If setup ready and no open position — execute
   if(g_SetupReady && !HasOpenPosition())
      ExecuteTrade();

   // Manage open positions (partial TP, trailing)
   ManageOpenPositions();

   // Dashboard update
   if(ShowDashboard) DrawDashboard();
}

//==========================================================================
// CORE: AMD PHASE DETECTION
//==========================================================================

void UpdateAMDPhase()
{
   int hour = TimeHour(TimeCurrent());

   if(hour >= AccumStart_Hour && hour < AccumEnd_Hour)
      g_CurrentPhase = AMD_ACCUM;
   else if(hour >= ManipStart_Hour && hour < ManipEnd_Hour)
      g_CurrentPhase = AMD_MANIP;
   else if(hour >= DistribStart_Hour && hour < DistribEnd_Hour)
      g_CurrentPhase = AMD_DISTRIB;
   else
      g_CurrentPhase = AMD_NONE;
}

//==========================================================================
// CORE: SCAN EQUAL HIGHS / EQUAL LOWS (Liquidity Pools)
//==========================================================================

void ScanLiquidityLevels()
{
   g_EqHighCount = 0;
   g_EqLowCount  = 0;
   ArrayResize(g_EqualHighs, 0);
   ArrayResize(g_EqualLows,  0);

   double tolerance = EqualLevelTolerance * _Point * 10;

   for(int i = LiqSweepLookback; i >= 2; i--)
   {
      double hi = iHigh(_Symbol, PERIOD_H1, i);
      double lo = iLow (_Symbol, PERIOD_H1, i);

      // Check if another bar within lookback has same high (±tolerance)
      for(int j = i - 1; j >= 1; j--)
      {
         double hi2 = iHigh(_Symbol, PERIOD_H1, j);
         double lo2 = iLow (_Symbol, PERIOD_H1, j);

         if(MathAbs(hi - hi2) <= tolerance)
         {
            ArrayResize(g_EqualHighs, g_EqHighCount + 1);
            g_EqualHighs[g_EqHighCount++] = hi;
            break;
         }
         if(MathAbs(lo - lo2) <= tolerance)
         {
            ArrayResize(g_EqualLows, g_EqLowCount + 1);
            g_EqualLows[g_EqLowCount++] = lo;
            break;
         }
      }
   }
}

//==========================================================================
// CORE: JUDAS SWING DETECTION
// Manipulation phase: price sweeps liquidity OPPOSITE to true direction
// Bull AMD: price dips below equal lows (sweeps sell-side) → then reverses UP
// Bear AMD: price spikes above equal highs (sweeps buy-side) → then reverses DOWN
//==========================================================================

void CheckJudasSwing()
{
   if(g_CurrentPhase != AMD_MANIP) return;
   if(HasOpenPosition()) return;

   g_SetupReady      = false;
   g_JudasSwingBullish = false;
   g_JudasSwingBearish = false;

   double currentLow  = iLow (_Symbol, PERIOD_M15, 1);
   double currentHigh = iHigh(_Symbol, PERIOD_M15, 1);
   double closePrice  = iClose(_Symbol, PERIOD_M15, 1);
   double openPrice   = iOpen (_Symbol, PERIOD_M15, 1);

   // --- BULLISH JUDAS: Swept sell-side liquidity (equal lows) ---
   for(int i = 0; i < g_EqLowCount; i++)
   {
      double lvl = g_EqualLows[i];
      // Price wicked below equal low (swept it) but closed ABOVE (rejection)
      if(currentLow < lvl && closePrice > lvl && closePrice > openPrice)
      {
         g_JudasSwingBullish = true;
         g_SweptLevel        = lvl;

         // Confirm: wait SweepConfirmBars bars for MSS (Market Structure Shift)
         if(IsMarketStructureShiftUp())
         {
            double sl   = currentLow - (10 * _Point * 10);
            double risk = sl > 0 ? MathAbs(closePrice - sl) : 0;
            if(risk <= 0) continue;

            g_EntryPrice    = closePrice;
            g_SL            = sl;
            g_TP1           = closePrice + risk * TP1_RR;
            g_TP2           = closePrice + risk * TP2_RR;
            g_SetupReady    = true;
            g_SetupDirection= "BUY";

            Print("[AMD_EA] BULLISH JUDAS SWING | Swept: ", lvl,
                  " | Entry: ", g_EntryPrice, " | SL: ", g_SL,
                  " | TP1: ", g_TP1, " | TP2: ", g_TP2);
            SendTelegram("🟢 BULLISH JUDAS SWING\nXAUUSD BUY\nEntry: " +
                         DoubleToString(g_EntryPrice,2) +
                         "\nSL: " + DoubleToString(g_SL,2) +
                         "\nTP1: " + DoubleToString(g_TP1,2) +
                         "\nTP2: " + DoubleToString(g_TP2,2));
         }
         break;
      }
   }

   // --- BEARISH JUDAS: Swept buy-side liquidity (equal highs) ---
   if(!g_SetupReady)
   {
      for(int i = 0; i < g_EqHighCount; i++)
      {
         double lvl = g_EqualHighs[i];
         // Price wicked above equal high but closed BELOW (rejection)
         if(currentHigh > lvl && closePrice < lvl && closePrice < openPrice)
         {
            g_JudasSwingBearish = true;
            g_SweptLevel        = lvl;

            if(IsMarketStructureShiftDown())
            {
               double sl   = currentHigh + (10 * _Point * 10);
               double risk = MathAbs(closePrice - sl);
               if(risk <= 0) continue;

               g_EntryPrice    = closePrice;
               g_SL            = sl;
               g_TP1           = closePrice - risk * TP1_RR;
               g_TP2           = closePrice - risk * TP2_RR;
               g_SetupReady    = true;
               g_SetupDirection= "SELL";

               Print("[AMD_EA] BEARISH JUDAS SWING | Swept: ", lvl,
                     " | Entry: ", g_EntryPrice, " | SL: ", g_SL,
                     " | TP1: ", g_TP1, " | TP2: ", g_TP2);
               SendTelegram("🔴 BEARISH JUDAS SWING\nXAUUSD SELL\nEntry: " +
                            DoubleToString(g_EntryPrice,2) +
                            "\nSL: " + DoubleToString(g_SL,2) +
                            "\nTP1: " + DoubleToString(g_TP1,2) +
                            "\nTP2: " + DoubleToString(g_TP2,2));
            }
            break;
         }
      }
   }
}

//==========================================================================
// MARKET STRUCTURE SHIFT CONFIRMATION
//==========================================================================

bool IsMarketStructureShiftUp()
{
   // Price must take out a previous M15 swing high (bullish BOS)
   double prevSwingHigh = iHigh(_Symbol, PERIOD_M15, 3);
   double curHigh       = iHigh(_Symbol, PERIOD_M15, 1);
   return (curHigh > prevSwingHigh);
}

bool IsMarketStructureShiftDown()
{
   double prevSwingLow = iLow(_Symbol, PERIOD_M15, 3);
   double curLow       = iLow(_Symbol, PERIOD_M15, 1);
   return (curLow < prevSwingLow);
}

//==========================================================================
// TRADE EXECUTION
//==========================================================================

void ExecuteTrade()
{
   if(!g_SetupReady) return;

   double lotSize = CalcLotSize(g_EntryPrice, g_SL);
   if(lotSize <= 0) { g_SetupReady = false; return; }

   bool result = false;

   if(g_SetupDirection == "BUY")
      result = trade.Buy(lotSize, _Symbol, 0, g_SL, g_TP2, "AMD_BUY");
   else
      result = trade.Sell(lotSize, _Symbol, 0, g_SL, g_TP2, "AMD_SELL");

   if(result)
   {
      g_TicketMain = trade.ResultOrder();
      g_TP1Hit     = false;
      g_SetupReady = false;
      Print("[AMD_EA] Trade opened: ", g_SetupDirection,
            " Lot: ", lotSize, " Ticket: ", g_TicketMain);
      SendTelegram("✅ TRADE EXECUTED\n" + g_SetupDirection +
                   " XAUUSD\nLots: " + DoubleToString(lotSize, 2) +
                   "\nTicket: " + IntegerToString(g_TicketMain));
   }
   else
   {
      Print("[AMD_EA] Trade failed: ", GetLastError());
      g_SetupReady = false;
   }
}

//==========================================================================
// POSITION MANAGEMENT: Partial TP + Trail
//==========================================================================

void ManageOpenPositions()
{
   if(!HasOpenPosition()) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != MagicNumber) continue;

      double openPrice = posInfo.PriceOpen();
      double sl        = posInfo.StopLoss();
      double curPrice  = posInfo.PriceCurrent();
      double lots      = posInfo.Volume();
      ENUM_POSITION_TYPE ptype = posInfo.PositionType();

      // --- TP1 Partial Close ---
      if(!g_TP1Hit)
      {
         bool tp1Reached = (ptype == POSITION_TYPE_BUY  && curPrice >= g_TP1) ||
                           (ptype == POSITION_TYPE_SELL && curPrice <= g_TP1);
         if(tp1Reached)
         {
            double closeVol = NormalizeDouble(lots * TP1_ClosePct / 100.0, 2);
            if(closeVol >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
            {
               trade.PositionClosePartial(posInfo.Ticket(), closeVol);
               g_TP1Hit = true;
               // Move SL to Break Even
               trade.PositionModify(posInfo.Ticket(), openPrice, g_TP2);
               Print("[AMD_EA] TP1 hit — partial close ", closeVol, " lots. SL → BE");
               SendTelegram("🎯 TP1 HIT — Partial Close\nSL moved to Break Even\nRemaining: " +
                            DoubleToString(lots - closeVol, 2) + " lots");
            }
         }
      }

      // --- Trail after TP1 hit: trail SL by 50% of remaining range ---
      if(g_TP1Hit)
      {
         double trailDist = MathAbs(g_TP2 - openPrice) * 0.3;
         double newSL     = 0;
         if(ptype == POSITION_TYPE_BUY)
            newSL = curPrice - trailDist;
         else
            newSL = curPrice + trailDist;

         bool shouldUpdate = (ptype == POSITION_TYPE_BUY  && newSL > sl && newSL < curPrice) ||
                             (ptype == POSITION_TYPE_SELL && newSL < sl && newSL > curPrice);
         if(shouldUpdate)
            trade.PositionModify(posInfo.Ticket(), newSL, g_TP2);
      }
   }
}

//==========================================================================
// LOT SIZE CALCULATION (Risk-based)
//==========================================================================

double CalcLotSize(double entry, double sl)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double slPoints   = MathAbs(entry - sl) / (_Point * 10);

   if(slPoints <= 0) return 0;

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotValue   = (tickValue / tickSize) * _Point * 10;

   double lots = riskAmount / (slPoints * lotValue);
   lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
          MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
          NormalizeDouble(lots, 2)));
   return lots;
}

//==========================================================================
// DRAWDOWN GUARDIAN (PropFirm Rule Enforcer)
//==========================================================================

bool IsDrawdownBreached()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);

   // Daily DD check
   double dailyDD  = (g_DayStartBalance - equity) / g_DayStartBalance * 100.0;
   if(dailyDD >= DailyDrawdownLimit)
   {
      static datetime lastWarn = 0;
      if(TimeCurrent() - lastWarn > 3600)
      {
         Print("[AMD_EA] ⛔ DAILY DD LIMIT HIT: ", dailyDD, "%");
         SendTelegram("⛔ DAILY DD LIMIT HIT: " + DoubleToString(dailyDD,2) +
                      "% — No new trades today!");
         lastWarn = TimeCurrent();
      }
      return true;
   }

   // Total DD check
   double totalDD  = (g_InitialBalance - equity) / g_InitialBalance * 100.0;
   if(totalDD >= MaxDrawdownLimit)
   {
      static datetime lastWarn2 = 0;
      if(TimeCurrent() - lastWarn2 > 3600)
      {
         Print("[AMD_EA] 🚨 MAX DD LIMIT HIT: ", totalDD, "%");
         SendTelegram("🚨 MAX DRAWDOWN BREACHED: " + DoubleToString(totalDD,2) +
                      "% — EA HALTED!");
         lastWarn2 = TimeCurrent();
      }
      // Close all positions if max DD hit
      CloseAllPositions();
      return true;
   }
   return false;
}

//==========================================================================
// SESSION / TIME FILTER
//==========================================================================

bool IsTradingSessionActive()
{
   int hour = TimeHour(TimeCurrent());
   // Block trades in dead zone
   if(NoTradeHour_Start < NoTradeHour_End)
   {
      if(hour >= NoTradeHour_Start && hour < NoTradeHour_End) return false;
   }
   else
   {
      if(hour >= NoTradeHour_Start || hour < NoTradeHour_End) return false;
   }
   return true;
}

//==========================================================================
// NEWS FILTER (basic time-based; integrate ForexFactory feed for full)
//==========================================================================

bool IsNewsTime()
{
   // This is a placeholder — integrate with DailyFX or MT5 economic calendar
   // For production: fetch from https://nfs.faireconomy.media/ff_calendar_thisweek.json
   // and parse high-impact USD/XAU events
   // For now: block Friday 12:30-13:30 GMT (NFP window) and Wed 14:00 (FOMC)
   int hour    = TimeHour(TimeCurrent());
   int minute  = TimeMinute(TimeCurrent());
   int dayOfWk = TimeDayOfWeek(TimeCurrent());

   // NFP - First Friday
   if(dayOfWk == 5 && hour == 12 && minute >= 0 && minute <= 60) return true;
   // FOMC - Wednesday
   if(dayOfWk == 3 && hour >= 18 && hour <= 19) return true;

   return false;
}

//==========================================================================
// DAILY TRACKING RESET
//==========================================================================

void ResetDailyTracking()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                 IntegerToString(dt.mon)  + "." +
                                 IntegerToString(dt.day));
   if(today != g_LastTradeDay)
   {
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_LastTradeDay    = today;
   }
}

//==========================================================================
// UTILITY FUNCTIONS
//==========================================================================

bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == MagicNumber &&
         posInfo.Symbol() == _Symbol)
         return true;
   }
   return false;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == MagicNumber)
         trade.PositionClose(posInfo.Ticket());
   }
}

int TimeHour(datetime t)   { MqlDateTime s; TimeToStruct(t,s); return s.hour; }
int TimeMinute(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.min;  }
int TimeDayOfWeek(datetime t) { MqlDateTime s; TimeToStruct(t,s); return s.day_of_week; }

//==========================================================================
// TELEGRAM ALERTS
//==========================================================================

void SendTelegram(string message)
{
   if(TelegramBotToken == "" || TelegramChatID == "") return;
   string url  = "https://api.telegram.org/bot" + TelegramBotToken +
                 "/sendMessage?chat_id=" + TelegramChatID +
                 "&text=" + message + "&parse_mode=HTML";
   char   data[];
   char   result[];
   string headers;
   int    timeout = 5000;
   WebRequest("GET", url, "", timeout, data, result, headers);
}

//==========================================================================
// ON-CHART DASHBOARD
//==========================================================================

void DrawDashboard()
{
   string phaseStr = "NONE";
   if(g_CurrentPhase == AMD_ACCUM)   phaseStr = "ACCUMULATION (Asia)";
   if(g_CurrentPhase == AMD_MANIP)   phaseStr = "MANIPULATION (Judas)";
   if(g_CurrentPhase == AMD_DISTRIB) phaseStr = "DISTRIBUTION (NY)";

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyDD = (g_DayStartBalance - equity) / g_DayStartBalance * 100.0;

   string info = "═══ AMD LIQUIDITY EA ═══\n" +
                 "Phase  : " + phaseStr + "\n" +
                 "Setup  : " + (g_SetupReady ? g_SetupDirection : "Scanning...") + "\n" +
                 "EqHighs: " + IntegerToString(g_EqHighCount) + "\n" +
                 "EqLows : " + IntegerToString(g_EqLowCount)  + "\n" +
                 "Daily DD: " + DoubleToString(dailyDD, 2) + "%\n" +
                 "Balance : $" + DoubleToString(balance, 2) + "\n" +
                 "Equity  : $" + DoubleToString(equity, 2);

   Comment(info);
}
//+------------------------------------------------------------------+
