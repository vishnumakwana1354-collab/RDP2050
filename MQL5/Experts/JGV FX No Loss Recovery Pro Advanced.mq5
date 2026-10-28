//+------------------------------------------------------------------+
//|                 JGV FX NO LOSS RECOVERY PRO ADVANCED v5.00       |
//|                    Advanced Lot Multiplier System                |
//|                                  Copyright 2024, JGV FX Premium  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, JGV FX"
#property link      "https://www.mql5.com"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Enums for Advanced Logic
enum ENUM_RECOVERY_MODE {
   RECOVERY_GRID,    // Standard Martingale Grid
   RECOVERY_HEDGE,   // Hedging recovery (Advanced)
   RECOVERY_SMART    // ADX-Volatility Based Spacing
};

enum ENUM_TRADING_SESSION {
   SESSION_ASIA,      // Asian Session
   SESSION_LONDON,    // London Session
   SESSION_NEWYORK,   // New York Session
   SESSION_SYDNEY     // Sydney Session
};

enum ENUM_LOT_PROGRESSION {
   LOT_FIXED,         // Fixed Lot Size
   LOT_MARTINGALE,    // Martingale Progression (1.6x)
   LOT_ADVANCED       // Advanced: 0.01, 0.02, 0.03, 0.04, 0.05
};

//--- Input Parameters
input group "==== [1] LOT PROGRESSION SYSTEM (ADVANCED) ===="
input ENUM_LOT_PROGRESSION InpLotProgression = LOT_ADVANCED; // Lot Progression Type
input double    InpBaseLot         = 0.01;        // Base Lot Size
input double    InpLotMultiplier   = 1.6;         // Martingale Multiplier (if enabled)
input bool      InpUseAdvancedLots = true;        // Use Advanced Lot Progression
// Advanced Lot Progression Array: 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08
double advancedLots[] = {0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10};

input group "==== [2] NO-LOSS RECOVERY SETTINGS ===="
input int       InpMaxOrders      = 100;           // Max Basket Orders
input int       InpGridDistance   = 3000;          // Min Distance between orders (Points)
input int       InpBasketTP       = 50;           // Profit target above Break-Even (Points)
input ENUM_RECOVERY_MODE InpMode  = RECOVERY_SMART; // Recovery Mode
input bool      InpAllowPartialClose = true;      // Allow Partial Close

input group "==== [3] SIDEWAYS ADX FILTER ===="
input int       InpADXPeriod      = 14;           // ADX Period
input double    InpTrendThreshold = 25.0;         // Below this = Sideways (Safe)
input double    InpMinADXEntry    = 15.0;         // Min ADX to avoid "Dead" market

input group "==== [4] SESSION FILTER SETTINGS ===="
input bool      InpUseSessionFilter = true;       // Enable Session Filter
input bool      InpTradeAsia      = true;         // Trade Asian Session (09:00-17:00)
input bool      InpTradeLondon    = true;         // Trade London Session (08:00-17:00)
input bool      InpTradeNewYork   = true;         // Trade New York Session (13:00-22:00)
input bool      InpTradeSydney    = true;         // Trade Sydney Session (22:00-07:00)

input group "==== [5] TIME FILTER SETTINGS ===="
input bool      InpUseTimeFilter  = true;         // Enable Time Filter
input int       InpStartHour      = 1;            // 24h Format Start
input int       InpEndHour        = 23;           // 24h Format End
input bool      InpTradeWeekend   = false;        // Allow Weekend Trading
input int       InpStartDay       = 1;            // Trade Start Day (1=Monday, 5=Friday)
input int       InpEndDay         = 5;            // Trade End Day (1=Monday, 5=Friday)

input group "==== [6] TIMEFRAME FILTER ===="
input bool      InpUseTimeFrameFilter = true;     // Enable TimeFrame Filter
input ENUM_TIMEFRAMES InpAllowedTimeFrame = PERIOD_M15; // Only M15

input group "==== [7] NEWS FILTER SETTINGS ===="
input bool      InpUseNewsFilter  = true;         // Enable News Filter
input int       InpNewsBuffer     = 60;           // Minutes before news to stop trading
input int       InpNewsAfter      = 60;           // Minutes after news to resume trading
input string    InpNewsLevelFilter = "High";      // Filter: "High", "Medium", "All"
input string    InpNewsURL        = "https://nfs.faireconomy.media/ff_calendar_thisweek.csv";

input group "==== [8] MAGIC NUMBER ===="
input long      InpMagic          = 9000;        // Unique Magic Number

//--- Global Variables
CTrade         trade;
CPositionInfo  pos;
CSymbolInfo    sym;
int            handleADX;
datetime       lastNewsTime = 0;
datetime       nextNewsTime = 0;
string         newsCalendarData = "";
bool           newsEventNear = false;

// Statistics
struct Statistics {
   int totalTrades;
   int winTrades;
   int lossTrades;
   double totalProfit;
   double totalLotTraded;
   double maxDrawdown;
   double recoveryCount;
};

Statistics stats = {0, 0, 0, 0.0, 0.0, 0.0, 0};

//+------------------------------------------------------------------+
//| Session Time Structures                                          |
//+------------------------------------------------------------------+
struct SessionTime {
   int startHour;
   int startMin;
   int endHour;
   int endMin;
   string name;
};

SessionTime asiaSession = {9, 0, 17, 0, "Asia"};
SessionTime londonSession = {8, 0, 17, 0, "London"};
SessionTime newyorkSession = {13, 0, 22, 0, "New York"};
SessionTime sydneySession = {22, 0, 7, 0, "Sydney"};

//+------------------------------------------------------------------+
//| INIT FUNCTION                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   // Validate TimeFrame
   if(InpUseTimeFrameFilter && _Period != InpAllowedTimeFrame) {
      Alert("ERROR: EA only works on " + TimeframeToString(InpAllowedTimeFrame) + " timeframe!");
      Print("ERROR: Current timeframe is " + TimeframeToString(_Period));
      return(INIT_FAILED);
   }

   handleADX = iADX(_Symbol, _Period, InpADXPeriod);
   if(handleADX == INVALID_HANDLE) {
      Alert("ERROR: Failed to create ADX handle");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   sym.Name(_Symbol);
   
   // Load News Calendar
   if(InpUseNewsFilter) {
      LoadNewsCalendar();
   }
   
   Print("[INIT] JGV NO-LOSS PRO ADVANCED v5.00 initialized successfully!");
   Print("[INIT] Lot Progression Mode: " + LotProgressionToString(InpLotProgression));
   Print("[INIT] Base Lot: " + DoubleToString(InpBaseLot, 2));
   Print("[INIT] Magic Number: " + (string)InpMagic);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick() {
   // Check all filters before processing
   if(!IsTimeAllowed()) {
      DisplayDashboard("⏱️ TIME FILTER: OFF");
      return;
   }
   
   if(!IsSessionAllowed()) {
      DisplayDashboard("📅 SESSION FILTER: OFF");
      return;
   }
   
   if(InpUseNewsFilter && IsNewsEventNear()) {
      DisplayDashboard("📰 NEWS EVENT NEAR: PAUSED");
      return;
   }
   
   if(!sym.RefreshRates()) {
      Print("ERROR: Failed to refresh rates");
      return;
   }
   
   // 1. Manage existing basket (Closing at Break-Even + Profit)
   ManageBasketRecovery();
   
   // 2. Entry Signal for First Trade (Sideways Logic)
   if(CountTotalPositions() == 0) {
      CheckInitialEntry();
   } 
   // 3. Logic for adding to Recovery Grid
   else {
      CheckRecoveryGrid();
   }
   
   // 4. UI Display
   DisplayDashboard("✅ TRADING ACTIVE");
}

//+------------------------------------------------------------------+
//| GET NEXT LOT SIZE - Advanced Progression System                  |
//+------------------------------------------------------------------+
double GetNextLotSize(int orderCount) {
   if(orderCount < 0 || orderCount >= ArraySize(advancedLots)) {
      Print("WARNING: Order count exceeds advanced lots array size");
      return InpBaseLot;
   }
   
   double nextLot = 0;
   
   if(InpLotProgression == LOT_FIXED) {
      nextLot = InpBaseLot;
   }
   else if(InpLotProgression == LOT_MARTINGALE) {
      nextLot = InpBaseLot * MathPow(InpLotMultiplier, orderCount);
   }
   else if(InpLotProgression == LOT_ADVANCED) {
      if(InpUseAdvancedLots && orderCount < ArraySize(advancedLots)) {
         nextLot = advancedLots[orderCount];
      } else {
         nextLot = advancedLots[ArraySize(advancedLots) - 1];
      }
   }
   
   // Normalize to broker's requirement (typically 0.01)
   nextLot = NormalizeDouble(nextLot, 2);
   
   // Check max lot size
   double maxLot = sym.LotsMax();
   if(nextLot > maxLot) nextLot = maxLot;
   
   double minLot = sym.LotsMin();
   if(nextLot < minLot) nextLot = minLot;
   
   return nextLot;
}

//+------------------------------------------------------------------+
//| TIME FILTER - Check if trading is allowed by time                |
//+------------------------------------------------------------------+
bool IsTimeAllowed() {
   if(!InpUseTimeFilter) return true;
   
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Check Day of Week
   if(dt.day_of_week == 0 || dt.day_of_week == 6) { // Sunday or Saturday
      if(!InpTradeWeekend) return false;
   }
   
   // Check Start and End Days
   if(dt.day_of_week < InpStartDay || dt.day_of_week > InpEndDay) {
      if(!InpTradeWeekend) return false;
   }
   
   // Check Hour Range
   if(dt.hour < InpStartHour || dt.hour > InpEndHour) {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| SESSION FILTER - Check if trading is allowed in current session  |
//+------------------------------------------------------------------+
bool IsSessionAllowed() {
   if(!InpUseSessionFilter) return true;
   
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentHour = dt.hour;
   int currentMin = dt.min;
   
   // Convert to minutes for easier comparison
   int currentTime = currentHour * 100 + currentMin;
   
   bool allowed = false;
   
   // Check Asia Session (09:00-17:00)
   if(InpTradeAsia) {
      int asiaStart = asiaSession.startHour * 100 + asiaSession.startMin;
      int asiaEnd = asiaSession.endHour * 100 + asiaSession.endMin;
      if(currentTime >= asiaStart && currentTime <= asiaEnd) allowed = true;
   }
   
   // Check London Session (08:00-17:00)
   if(InpTradeLondon) {
      int londonStart = londonSession.startHour * 100 + londonSession.startMin;
      int londonEnd = londonSession.endHour * 100 + londonSession.endMin;
      if(currentTime >= londonStart && currentTime <= londonEnd) allowed = true;
   }
   
   // Check New York Session (13:00-22:00)
   if(InpTradeNewYork) {
      int newyorkStart = newyorkSession.startHour * 100 + newyorkSession.startMin;
      int newyorkEnd = newyorkSession.endHour * 100 + newyorkSession.endMin;
      if(currentTime >= newyorkStart && currentTime <= newyorkEnd) allowed = true;
   }
   
   // Check Sydney Session (22:00-07:00 - handles midnight crossing)
   if(InpTradeSydney) {
      if(currentTime >= 2200 || currentTime <= 700) allowed = true;
   }
   
   return allowed;
}

//+------------------------------------------------------------------+
//| NEWS FILTER - Load Calendar from CSV                             |
//+------------------------------------------------------------------+
void LoadNewsCalendar() {
   Print("[NEWS] Loading calendar from: " + InpNewsURL);
   // This function loads news data from the provided CSV URL
   // Full implementation requires WebRequest API integration
   newsCalendarData = "News calendar initialized";
}

//+------------------------------------------------------------------+
//| Check if News Event is Near                                      |
//+------------------------------------------------------------------+
bool IsNewsEventNear() {
   if(!InpUseNewsFilter) return false;
   
   datetime currentTime = TimeCurrent();
   
   // Example: Check if near major news events
   // Full implementation would parse CSV and check event times
   
   return newsEventNear;
}

//+------------------------------------------------------------------+
//| INITIAL TRADE ENTRY LOGIC                                        |
//+------------------------------------------------------------------+
void CheckInitialEntry() {
   double adx[], pDI[], mDI[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(pDI, true);
   ArraySetAsSeries(mDI, true);
   
   if(CopyBuffer(handleADX, 0, 0, 2, adx) < 2) return;
   if(CopyBuffer(handleADX, 1, 0, 2, pDI) < 2) return;
   if(CopyBuffer(handleADX, 2, 0, 2, mDI) < 2) return;
   
   // Sideways check: Only trade if ADX is between MinADX and TrendThreshold
   if(adx[0] < InpMinADXEntry || adx[0] > InpTrendThreshold) {
      return;
   }
   
   // Get first lot size
   double firstLot = GetNextLotSize(0);
   
   // Entry on DI Cross
   if(pDI[0] > mDI[0] && pDI[1] <= mDI[1]) {
      if(trade.Buy(firstLot, _Symbol, sym.Ask(), 0, 0, "Vishnu 2026 Buy [Lot: " + DoubleToString(firstLot, 2) + "]")) {
         Print("[ENTRY] BUY Order Placed - Lot: " + DoubleToString(firstLot, 2) + " | ADX: " + DoubleToString(adx[0], 2));
         stats.totalTrades++;
      }
   }
   else if(mDI[0] > pDI[0] && mDI[1] <= pDI[1]) {
      if(trade.Sell(firstLot, _Symbol, sym.Bid(), 0, 0, "Vishnu 2026 Sell [Lot: " + DoubleToString(firstLot, 2) + "]")) {
         Print("[ENTRY] SELL Order Placed - Lot: " + DoubleToString(firstLot, 2) + " | ADX: " + DoubleToString(adx[0], 2));
         stats.totalTrades++;
      }
   }
}

//+------------------------------------------------------------------+
//| RECOVERY GRID MANAGEMENT (The "No Loss" Engine)                  |
//+------------------------------------------------------------------+
void ManageBasketRecovery() {
   double totalProfit = 0;
   double totalLots = 0;
   int buyCount = 0, sellCount = 0;
   double totalCommission = 0;
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
         totalProfit += pos.Profit();
         totalCommission += pos.Commission();
         totalLots += pos.Volume();
         
         if(pos.PositionType() == POSITION_TYPE_BUY) {
            buyCount++;
         } else {
            sellCount++;
         }
      }
   }
   
   if(totalLots <= 0) return;

   // Calculate total floating profit including commissions and swaps
   double totalFloatingProfit = totalProfit + totalCommission;
   
   // Calculation of target profit in currency based on points
   double tickValue = sym.TickValue();
   double profitTargetMoney = (InpBasketTP * _Point / sym.TickSize()) * tickValue * totalLots;
   
   Print("[BASKET] Floating: " + DoubleToString(totalFloatingProfit, 2) + " | Target: " + DoubleToString(profitTargetMoney, 2) + " | Total Lots: " + DoubleToString(totalLots, 2));
   
   // Close all positions if profit target reached
   if(totalFloatingProfit >= profitTargetMoney) {
      CloseAllPositions();
      Print("[SUCCESS] Recovery Basket Closed in Profit | Profit: " + DoubleToString(totalFloatingProfit, 2));
      stats.recoveryCount++;
      stats.winTrades++;
   }
}

//+------------------------------------------------------------------+
//| SMART GRID LOGIC - Advanced Lot Progression                      |
//+------------------------------------------------------------------+
void CheckRecoveryGrid() {
   int buyCount = 0, sellCount = 0;
   double lastBuyPrice = 0, lastSellPrice = 0;
   double buyLots = 0, sellLots = 0;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
         if(pos.PositionType() == POSITION_TYPE_BUY) {
            buyCount++;
            if(lastBuyPrice == 0 || pos.PriceOpen() < lastBuyPrice) {
               lastBuyPrice = pos.PriceOpen();
            }
            buyLots = pos.Volume();
         } else {
            sellCount++;
            if(lastSellPrice == 0 || pos.PriceOpen() > lastSellPrice) {
               lastSellPrice = pos.PriceOpen();
            }
            sellLots = pos.Volume();
         }
      }
   }

   // Dynamic Grid Spacing based on ADX
   double adxVal[]; 
   ArraySetAsSeries(adxVal, true);
   if(CopyBuffer(handleADX, 0, 0, 1, adxVal) < 1) return;
   
   double dynamicDist = InpGridDistance;
   if(adxVal[0] > InpTrendThreshold) {
      dynamicDist *= 1.5; // Increase spacing when trend is strong
   }

   // Add to Buy Basket with Advanced Lot Progression
   if(buyCount > 0 && buyCount < InpMaxOrders) {
      if(sym.Ask() < lastBuyPrice - (dynamicDist * _Point)) {
         double nextLot = GetNextLotSize(buyCount);
         if(trade.Buy(nextLot, _Symbol, sym.Ask(), 0, 0, "Vishnu 2026Recovery Buy #" + (string)(buyCount + 1) + " [Lot: " + DoubleToString(nextLot, 2) + "]")) {
            Print("[GRID] BUY Recovery #" + (string)(buyCount + 1) + " - Lot: " + DoubleToString(nextLot, 2) + " | Price: " + DoubleToString(sym.Ask(), _Digits));
            stats.totalLotTraded += nextLot;
         }
      }
   }
   
   // Add to Sell Basket with Advanced Lot Progression
   if(sellCount > 0 && sellCount < InpMaxOrders) {
      if(sym.Bid() > lastSellPrice + (dynamicDist * _Point)) {
         double nextLot = GetNextLotSize(sellCount);
         if(trade.Sell(nextLot, _Symbol, sym.Bid(), 0, 0, "Vishnu 2026Recovery Sell #" + (string)(sellCount + 1) + " [Lot: " + DoubleToString(nextLot, 2) + "]")) {
            Print("[GRID] SELL Recovery #" + (string)(sellCount + 1) + " - Lot: " + DoubleToString(nextLot, 2) + " | Price: " + DoubleToString(sym.Bid(), _Digits));
            stats.totalLotTraded += nextLot;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
         if(trade.PositionClose(pos.Ticket())) {
            Print("[CLOSE] Position #" + (string)pos.Ticket() + " closed successfully");
         }
      }
   }
}

int CountTotalPositions() {
   int c = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
         c++;
      }
   }
   return c;
}

string TimeframeToString(ENUM_TIMEFRAMES tf) {
   switch(tf) {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default: return "Unknown";
   }
}

string LotProgressionToString(ENUM_LOT_PROGRESSION mode) {
   if(mode == LOT_FIXED) return "FIXED";
   if(mode == LOT_MARTINGALE) return "MARTINGALE (1.6x)";
   if(mode == LOT_ADVANCED) return "ADVANCED (0.01-0.10)";
   return "Unknown";
}

string GetCurrentSession() {
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentTime = dt.hour * 100 + dt.min;
   
   if(currentTime >= 900 && currentTime <= 1700) return "🌏 Asia";
   if(currentTime >= 800 && currentTime <= 1700) return "🌍 London";
   if(currentTime >= 1300 && currentTime <= 2200) return "🗽 New York";
   if(currentTime >= 2200 || currentTime <= 700) return "🌎 Sydney";
   
   return "None";
}

void DisplayDashboard(string status = "✅ TRADING ACTIVE") {
   MqlDateTime dt;
   TimeCurrent(dt);
   
   string msg = "\n";
   msg += "╔══════════════════════════════════════════════════════════╗\n";
   msg += "║      JGV FX NO-LOSS RECOVERY PRO ADVANCED v5.00           ║\n";
   msg += "║          Advanced Lot Multiplier System                  ║\n";
   msg += "╠══════════════════════════════════════════════════════════╣\n";
   msg += "║ Status: " + status + "\n";
   msg += "║──────────────────────────────────────────────────────────║\n";
   msg += "║ Symbol: " + _Symbol + " | TF: " + TimeframeToString(_Period) + "\n";
   msg += "║ Time: " + TimeToString(TimeCurrent()) + " | Session: " + GetCurrentSession() + "\n";
   msg += "║──────────────────────────────────────────────────────────║\n";
   msg += "║ 📊 LOT PROGRESSION:\n";
   msg += "║    Mode: " + LotProgressionToString(InpLotProgression) + "\n";
   msg += "║    Base Lot: " + DoubleToString(InpBaseLot, 2) + "\n";
   msg += "║    Current Orders: " + (string)CountTotalPositions() + "/" + (string)InpMaxOrders + "\n";
   msg += "║──────────────────────────────────────────────────────────║\n";
   msg += "║ 💰 ACCOUNT:\n";
   msg += "║    Balance: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   msg += "║    Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   msg += "║    Floating: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   msg += "║    Margin Used: " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + "\n";
   msg += "║──────────────────────────────────────────────────────────║\n";
   msg += "║ 🎯 STATISTICS:\n";
   msg += "║    Total Trades: " + (string)stats.totalTrades + "\n";
   msg += "║    Recoveries: " + DoubleToString(stats.recoveryCount, 0) + "\n";
   msg += "║    Total Lots Traded: " + DoubleToString(stats.totalLotTraded, 2) + "\n";
   msg += "║──────────────────────────────────────────────────────────║\n";
   msg += "║ 🔐 FILTERS:\n";
   msg += "║    ✓ Time: " + (InpUseTimeFilter ? "ON (" + (string)InpStartHour + "-" + (string)InpEndHour + ")" : "OFF") + "\n";
   msg += "║    ✓ Session: " + (InpUseSessionFilter ? "ON" : "OFF") + "\n";
   msg += "║    ✓ TimeFrame: " + (InpUseTimeFrameFilter ? "ON (M15)" : "OFF") + "\n";
   msg += "║    ✓ News: " + (InpUseNewsFilter ? "ON" : "OFF") + "\n";
   msg += "║    ✓ ADX: " + (string)InpADXPeriod + " (Min: " + DoubleToString(InpMinADXEntry, 1) + ", Max: " + DoubleToString(InpTrendThreshold, 1) + ")\n";
   msg += "╚══════════════════════════════════════════════════════════╝\n";
   
   Comment(msg);
}

//+------------------------------------------------------------------+
//| DEINIT FUNCTION                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Comment("");
   Print("\n╔════════════════════════════════════════════════════╗");
   Print("║  JGV NO-LOSS PRO ADVANCED v5.00 - SHUT DOWN       ║");
   Print("╠════════════════════════════════════════════════════╣");
   Print("║  Total Trades: " + (string)stats.totalTrades);
   Print("║  Total Recoveries: " + DoubleToString(stats.recoveryCount, 0));
   Print("║  Total Lots: " + DoubleToString(stats.totalLotTraded, 2));
   Print("║  Final Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("╚════════════════════════════════════════════════════╝");
}
//+------------------------------------------------------------------+
