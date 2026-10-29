//+------------------------------------------------------------------+
//|                                              XAUUSD_Gold_EA.mq5 |
//|                                   Advanced Gold Trading System   |
//|                                              Version 1.0 - 2027  |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Gold EA System"
#property version   "1.00"
#property description "Complete 6-IDEA Gold Trading System"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

// Global Objects
CTrade trade;
CPositionInfo position;
CAccountInfo account;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

// === IDEA 1: Key Level Lines ===
input group "IDEA 1 — Key Level Lines"
input int DailyLookback = 4;                    // Daily lookback period
input double FibLevel = 0.68;                   // Fibonacci 0.68 level

// === IDEA 3: Indicator Filters ===
input group "IDEA 3 — Indicator Filters"
input int RSI_Period = 14;                      // RSI Period
input int Stoch_K = 14;                         // Stochastic K
input int Stoch_D = 1;                          // Stochastic D
input int Stoch_Slowing = 3;                    // Stochastic Slowing
input int ATR_Period = 14;                      // ATR Period
input int ADX_Period = 14;                      // ADX Period

// === IDEA 4: Protection System ===
input group "IDEA 4 — Protection System"
input int MaxSpread = 35;                       // Max spread in points
input int MaxSlippage = 5;                      // Max slippage in points
input int NewsBlockMinutesBefore = 15;          // News block before (minutes)
input int NewsBlockMinutesAfter = 15;           // News block after (minutes)
input double ATR_MinThreshold = 5.0;            // ATR minimum threshold
input double ATR_MaxThreshold = 150.0;          // ATR maximum threshold
input double DailyLossLimit_Small = 5.0;        // Daily loss limit under $100
input int SpreadCalmCandlesWait = 7;            // Candles to wait after spread spike

// === IDEA 5: TP/SL/Trailing/Lot Sizing ===
input group "IDEA 5 — TP/SL & Risk Management"
input double SL_ATR_Multiplier = 1.5;           // SL = ATR × this
input double TP_ATR_Multiplier = 3.0;           // TP = ATR × this (default)
input double Trailing_ATR_Multiplier = 1.0;     // Trailing = ATR × this
input double Breakeven_ATR_Trigger = 1.0;       // Breakeven trigger = ATR × this
input double PartialClosePercent = 50.0;        // Partial close percentage
input int MinSL_M1M5_Pips = 20;                 // Minimum SL on M1-M5 (pips)
input int MaxSL_M1M5_Pips = 40;                 // Maximum SL on M1-M5 (pips)
input int MinSL_M15_Pips = 40;                  // Minimum SL on M15 (pips)
input int MaxSL_M15_Pips = 80;                  // Maximum SL on M15 (pips)

// === IDEA 6: Entry Logic ===
input group "IDEA 6 — Entry Control"
input int MaxTradesPerDay_Small = 3;            // Max trades/day (balance < $100)
input int MaxTradesPerDay_Large = 5;            // Max trades/day (balance >= $100)
input double TargetTradesPerDay = 1.5;          // Target trades per day (1-2)

// === Progressive Weekly Targets ===
input group "Progressive Weekly Targets"
input bool UseProgressiveTargets = true;        // Use progressive weekly targets
input double Week1_Target = 100.0;              // Week 1 target: $100
input double Week2_Target = 500.0;              // Week 2 target: $500
input double Week3_Target = 1500.0;             // Week 3 target: $1,500
input double Week4_Target = 3000.0;             // Week 4 target: $3,000
input double Week5_Target = 5000.0;             // Week 5 target: $5,000
input double Week6_Target = 7000.0;             // Week 6 target: $7,000
input double Week7_Target = 12000.0;            // Week 7 target: $12,000
input double Week8_Target = 15000.0;            // Week 8 target: $15,000
input double Week9_Target = 20000.0;            // Week 9 target: $20,000
input double FinalTarget = 40000.0;             // Final target: $40,000

// === UI & Display ===
input group "UI Settings"
input bool ShowUI = true;                       // Show UI panel
input color UI_BackgroundColor = clrBlack;      // UI background color
input color UI_TextColor = clrWhite;            // UI text color
input int UI_Corner = CORNER_LEFT_UPPER;        // UI corner position
input int UI_X_Offset = 10;                     // UI X offset
input int UI_Y_Offset = 10;                     // UI Y offset

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+

// Handles for indicators
int handle_RSI_M15, handle_Stoch_M15, handle_ATR_M15, handle_ADX_M15;
int handle_RSI_M5, handle_Stoch_M5;
int handle_ATR_D1;

// New EMA handles for confluence scoring
int handle_EMA50_D1;    // Daily EMA 50 — trend alignment
int handle_EMA200_H1;   // H1 EMA 200 — trend alignment
int handle_EMA50_M15;   // M15 EMA 50 — trend alignment
int handle_EMA200_H4;   // H4 EMA 200 — institutional bias filter
int handle_MA200_M5;    // M5 SMA 200 — M5 white line feature

// Arrays for indicator values
double RSI_M15[], Stoch_Main_M15[], Stoch_Signal_M15[];
double ATR_M15[], ADX_Main[], ADX_Plus[], ADX_Minus[];
double RSI_M5[], Stoch_Main_M5[];
double ATR_D1[];

// New EMA arrays
double EMA50_D1[], EMA200_H1[], EMA50_M15[], EMA200_H4[], MA200_M5[];

// Key level tracking
double Daily_High = 0, Daily_Low = 0;
double H1_Fib_Level = 0;
double M15_Fib_Level = 0;

// Trading state
int TradesOpenedToday = 0;
datetime LastTradeDate = 0;
datetime CurrentDay = 0;
double DailyStartingEquity = 0;
double AccountHighWaterMark = 0;
int ConsecutiveLosses = 0;
datetime PauseUntil = 0;
bool TradingPausedToday = false;
bool TradingPausedForever = false;  // BUG 6: For 20% drawdown

// Spread spike tracking
datetime SpreadSpikeTime = 0;
int CandlesSinceSpreadNormal = 0;

// Session high/low tracking (BUG 2)
struct SessionHighLow {
    double High;
    double Low;
    datetime StartTime;
    bool IsActive;
};

SessionHighLow Asian_HL, London_HL, NewYork_HL;

// News calendar cache (BUG 1)
struct NewsEvent {
    datetime Time;
    string Currency;
};

NewsEvent NewsEvents[];
datetime LastNewsUpdate = 0;

// Session times (broker server time)
struct SessionTime {
    int StartHour;
    int StartMinute;
    int EndHour;
    int EndMinute;
};

SessionTime Asian = {0, 0, 6, 0};
SessionTime London = {8, 0, 12, 0};
SessionTime NewYork = {13, 0, 17, 0};

// Weekly target tracking
datetime StartDate = 0;
int CurrentWeek = 0;

// Smart Money tracking
struct OrderBlockInfo {
    double High;
    double Low;
    datetime Time;
    bool IsBullish;
    bool IsValid;
};

struct FVGInfo {
    double Upper;
    double Lower;
    datetime Time;
    bool IsBullish;
    bool IsValid;
};

OrderBlockInfo BullishOB, BearishOB;
FVGInfo BullishFVG, BearishFVG;

// UI Object names
string UI_Panel = "UI_MainPanel";
string UI_Label_Prefix = "UI_Label_";

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== XAUUSD Gold EA System Initialized ===");
    Print("Version: 1.0 - 2027 Edition");

    // Initialize indicator handles for M15
    handle_RSI_M15 = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);
    handle_Stoch_M15 = iStochastic(_Symbol, PERIOD_M15, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
    handle_ATR_M15 = iATR(_Symbol, PERIOD_M15, ATR_Period);
    handle_ADX_M15 = iADX(_Symbol, PERIOD_M15, ADX_Period);

    // Initialize indicator handles for M5
    handle_RSI_M5 = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
    handle_Stoch_M5 = iStochastic(_Symbol, PERIOD_M5, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);

    // Initialize ATR for Daily
    handle_ATR_D1 = iATR(_Symbol, PERIOD_D1, ATR_Period);

    // Initialize new EMA handles for confluence scoring
    handle_EMA50_D1 = iMA(_Symbol, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
    handle_EMA200_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
    handle_EMA50_M15 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
    handle_EMA200_H4 = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
    handle_MA200_M5 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_SMA, PRICE_CLOSE);

    // Check if handles are valid
    if(handle_RSI_M15 == INVALID_HANDLE || handle_Stoch_M15 == INVALID_HANDLE ||
       handle_ATR_M15 == INVALID_HANDLE || handle_ADX_M15 == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles for M15");
        return(INIT_FAILED);
    }

    if(handle_RSI_M5 == INVALID_HANDLE || handle_Stoch_M5 == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles for M5");
        return(INIT_FAILED);
    }

    if(handle_ATR_D1 == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ATR handle for D1");
        return(INIT_FAILED);
    }

    if(handle_EMA50_D1 == INVALID_HANDLE || handle_EMA200_H1 == INVALID_HANDLE ||
       handle_EMA50_M15 == INVALID_HANDLE || handle_EMA200_H4 == INVALID_HANDLE ||
       handle_MA200_M5 == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create EMA handles");
        return(INIT_FAILED);
    }

    // Set array as series
    ArraySetAsSeries(RSI_M15, true);
    ArraySetAsSeries(Stoch_Main_M15, true);
    ArraySetAsSeries(Stoch_Signal_M15, true);
    ArraySetAsSeries(ATR_M15, true);
    ArraySetAsSeries(ADX_Main, true);
    ArraySetAsSeries(ADX_Plus, true);
    ArraySetAsSeries(ADX_Minus, true);
    ArraySetAsSeries(RSI_M5, true);
    ArraySetAsSeries(Stoch_Main_M5, true);
    ArraySetAsSeries(ATR_D1, true);
    ArraySetAsSeries(EMA50_D1, true);
    ArraySetAsSeries(EMA200_H1, true);
    ArraySetAsSeries(EMA50_M15, true);
    ArraySetAsSeries(EMA200_H4, true);
    ArraySetAsSeries(MA200_M5, true);

    // Initialize account tracking
    AccountHighWaterMark = account.Balance();
    DailyStartingEquity = account.Equity();
    CurrentDay = iTime(_Symbol, PERIOD_D1, 0);
    StartDate = TimeCurrent();

    // Initialize Smart Money structures
    BullishOB.IsValid = false;
    BearishOB.IsValid = false;
    BullishFVG.IsValid = false;
    BearishFVG.IsValid = false;

    // Initialize session high/low tracking (BUG 2)
    Asian_HL.IsActive = false;
    London_HL.IsActive = false;
    NewYork_HL.IsActive = false;

    // Create UI
    if(ShowUI)
        CreateUI();

    // Draw key levels
    DrawKeyLevels();

    Print("Initialization complete. Starting balance: $", DoubleToString(account.Balance(), 2));
    Print("Target: $", DoubleToString(FinalTarget, 2));

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("=== EA Deinitialized. Reason: ", reason, " ===");

    // Release indicator handles
    if(handle_RSI_M15 != INVALID_HANDLE) IndicatorRelease(handle_RSI_M15);
    if(handle_Stoch_M15 != INVALID_HANDLE) IndicatorRelease(handle_Stoch_M15);
    if(handle_ATR_M15 != INVALID_HANDLE) IndicatorRelease(handle_ATR_M15);
    if(handle_ADX_M15 != INVALID_HANDLE) IndicatorRelease(handle_ADX_M15);
    if(handle_RSI_M5 != INVALID_HANDLE) IndicatorRelease(handle_RSI_M5);
    if(handle_Stoch_M5 != INVALID_HANDLE) IndicatorRelease(handle_Stoch_M5);
    if(handle_ATR_D1 != INVALID_HANDLE) IndicatorRelease(handle_ATR_D1);
    if(handle_EMA50_D1 != INVALID_HANDLE) IndicatorRelease(handle_EMA50_D1);
    if(handle_EMA200_H1 != INVALID_HANDLE) IndicatorRelease(handle_EMA200_H1);
    if(handle_EMA50_M15 != INVALID_HANDLE) IndicatorRelease(handle_EMA50_M15);
    if(handle_EMA200_H4 != INVALID_HANDLE) IndicatorRelease(handle_EMA200_H4);
    if(handle_MA200_M5 != INVALID_HANDLE) IndicatorRelease(handle_MA200_M5);

    // Clean up UI
    if(ShowUI)
        DeleteUI();

    // Clean up chart objects
    DeleteAllObjects();
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if new day started
    CheckNewDay();

    // Update key levels on new bar
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        DrawKeyLevels();
    }

    // BUG 3: Draw M5 200 MA (every tick)
    DrawM5_MA200();

    // Update Smart Money components (every tick)
    UpdateSmartMoneyComponents();

    // Manage open positions
    ManageOpenPositions();

    // Update UI
    if(ShowUI)
        UpdateUI();

    // Check for entry signals
    if(!IsAccountPaused())
        CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| BUG 5: Trade Transaction Event Handler                            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                         const MqlTradeRequest& request,
                         const MqlTradeResult& result)
{
    // Only process deal transactions
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;

    // Check if it's a position close
    if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL)
        return;

    // Get deal information
    ulong dealTicket = trans.deal;
    if(!HistoryDealSelect(dealTicket))
        return;

    // Check if deal is for our symbol
    if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
        return;

    // Check if it's a position exit (not entry)
    long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if(dealEntry != DEAL_ENTRY_OUT)
        return;

    // Get profit
    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

    // Update consecutive losses counter
    if(profit < 0)
    {
        ConsecutiveLosses++;
        Print("Loss detected. Consecutive losses: ", ConsecutiveLosses);

        // Pause for rest of day after 2 consecutive losses
        if(ConsecutiveLosses >= 2)
        {
            TradingPausedToday = true;
            Print("2 consecutive losses - Trading paused for rest of day");
        }

        // Pause for 24 hours after 3 consecutive losses
        if(ConsecutiveLosses >= 3)
        {
            PauseUntil = TimeCurrent() + 86400; // 24 hours
            Print("3 consecutive losses - Trading paused for 24 hours until ", TimeToString(PauseUntil));
        }
    }
    else if(profit > 0)
    {
        // Reset on win
        ConsecutiveLosses = 0;
        Print("Win detected. Consecutive losses counter reset");
    }
}

//+------------------------------------------------------------------+
//| Check if new day started and reset daily variables                |
//+------------------------------------------------------------------+
void CheckNewDay()
{
    datetime newDay = iTime(_Symbol, PERIOD_D1, 0);

    if(newDay != CurrentDay)
    {
        CurrentDay = newDay;
        TradesOpenedToday = 0;
        DailyStartingEquity = account.Equity();
        TradingPausedToday = false;
        CandlesSinceSpreadNormal = 0;

        // Calculate current week
        CurrentWeek = (int)((TimeCurrent() - StartDate) / (7 * 24 * 3600)) + 1;

        // BUG 1: Load news calendar for the day
        LoadNewsCalendar();

        // BUG 6: Update high water mark and check drawdown
        if(account.Balance() > AccountHighWaterMark)
            AccountHighWaterMark = account.Balance();

        Print("=== New Trading Day ===");
        Print("Current Week: ", CurrentWeek);
        Print("Starting Equity: $", DoubleToString(DailyStartingEquity, 2));
        Print("Balance: $", DoubleToString(account.Balance(), 2));
        Print("High Water Mark: $", DoubleToString(AccountHighWaterMark, 2));
    }
}

//+------------------------------------------------------------------+
//| BUG 1: Load News Calendar for the Day                             |
//+------------------------------------------------------------------+
void LoadNewsCalendar()
{
    ArrayResize(NewsEvents, 0);
    LastNewsUpdate = TimeCurrent();

    datetime today_start = iTime(_Symbol, PERIOD_D1, 0);
    datetime today_end = today_start + 86400; // 24 hours

    MqlCalendarValue values[];

    // Get calendar events for today
    int count = CalendarValueHistory(values, today_start, today_end);

    if(count <= 0)
    {
        Print("No news events found for today");
        return;
    }

    Print("Loading news calendar - found ", count, " potential events");

    for(int i = 0; i < count; i++)
    {
        MqlCalendarEvent event;
        if(!CalendarEventById(values[i].event_id, event))
            continue;

        MqlCalendarCountry country;
        if(!CalendarCountryById(event.country_id, country))
            continue;

        // Filter: Only USD and XAU currencies
        if(country.currency != "USD" && country.currency != "XAU")
            continue;

        // Filter: Only high importance
        if(event.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

        // Add to news events array
        int size = ArraySize(NewsEvents);
        ArrayResize(NewsEvents, size + 1);
        NewsEvents[size].Time = values[i].time;
        NewsEvents[size].Currency = country.currency;

        Print("High-impact news loaded: ", event.name, " at ", TimeToString(values[i].time), " (", country.currency, ")");
    }

    Print("Total high-impact news events loaded: ", ArraySize(NewsEvents));
}

//+------------------------------------------------------------------+
//| IDEA 1: Draw Key Level Lines                                      |
//+------------------------------------------------------------------+
void DrawKeyLevels()
{
    // Line 1: Orange Daily High/Low
    DrawDailyHighLow();

    // Line 2: White/Green 1H Fib 0.68
    DrawH1FibLevel();

    // Line 3: Blue 15M Fib 0.68 Trendline
    DrawM15FibLevel();
}

//+------------------------------------------------------------------+
//| Draw Daily High/Low (Orange)                                      |
//+------------------------------------------------------------------+
void DrawDailyHighLow()
{
    double highestHigh = 0;
    double lowestLow = DBL_MAX;

    // Look back ~4 days for swing high/low
    for(int i = 0; i < DailyLookback; i++)
    {
        double high = iHigh(_Symbol, PERIOD_D1, i);
        double low = iLow(_Symbol, PERIOD_D1, i);

        if(high > highestHigh)
            highestHigh = high;
        if(low < lowestLow)
            lowestLow = low;
    }

    Daily_High = highestHigh;
    Daily_Low = lowestLow;

    // Draw high line
    DrawHLine("Daily_High", Daily_High, clrOrange, 3, STYLE_SOLID);

    // Draw low line
    DrawHLine("Daily_Low", Daily_Low, clrOrange, 3, STYLE_SOLID);
}

//+------------------------------------------------------------------+
//| Draw 1H Fibonacci 0.68 Level (White/Green)                        |
//+------------------------------------------------------------------+
void DrawH1FibLevel()
{
    // Find swing high and low on 1H
    double high = iHigh(_Symbol, PERIOD_H1, iHighest(_Symbol, PERIOD_H1, MODE_HIGH, 20, 0));
    double low = iLow(_Symbol, PERIOD_H1, iLowest(_Symbol, PERIOD_H1, MODE_LOW, 20, 0));

    // Calculate 0.68 Fib level
    H1_Fib_Level = low + (high - low) * FibLevel;

    // Draw line
    DrawHLine("H1_Fib_068", H1_Fib_Level, clrLightGreen, 3, STYLE_SOLID);
}

//+------------------------------------------------------------------+
//| Draw 15M Fibonacci 0.68 Trendline (Blue) - BUG 10 FIXED          |
//+------------------------------------------------------------------+
void DrawM15FibLevel()
{
    // Find swing high and low on M15
    int highestBar = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, 30, 0);
    int lowestBar = iLowest(_Symbol, PERIOD_M15, MODE_LOW, 30, 0);

    double high = iHigh(_Symbol, PERIOD_M15, highestBar);
    double low = iLow(_Symbol, PERIOD_M15, lowestBar);

    // Calculate 0.68 Fib level
    M15_Fib_Level = low + (high - low) * FibLevel;

    // BUG 10 FIX: Draw as truly diagonal trendline
    // Point 1: Time of M15 swing low, price = M15 swing low
    // Point 2: Current time, price = current M15 Fib 0.68 level
    datetime time1 = iTime(_Symbol, PERIOD_M15, lowestBar);
    double price1 = low;  // Start at swing low
    datetime time2 = iTime(_Symbol, PERIOD_M15, 0);
    double price2 = M15_Fib_Level;  // End at current Fib level

    DrawTrendLine("M15_Fib_068_Trend", time1, price1, time2, price2, clrBlue, 3, STYLE_SOLID);
}

//+------------------------------------------------------------------+
//| IDEA 2: Update Smart Money Components                             |
//+------------------------------------------------------------------+
void UpdateSmartMoneyComponents()
{
    // Component A: Session High/Low (updated at session start)
    DrawSessionHighLow();

    // Component B: RSI + Stochastic Confluence Dot
    DrawRSIStochDots();

    // Component C: Candle Pattern Arrows
    DetectCandlePatterns();

    // Component D: Fair Value Gaps
    DetectFVG();

    // Component E: BIAS Line
    DrawBIASLine();

    // Component F: Order Blocks
    DetectOrderBlocks();
}

//+------------------------------------------------------------------+
//| Draw Session High/Low Lines                                       |
//+------------------------------------------------------------------+
void DrawSessionHighLow()
{
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    // Determine current session and draw its high/low
    if(IsInSession(dt, Asian))
    {
        DrawSessionLines("Asian", clrYellow);
    }
    else if(IsInSession(dt, London))
    {
        DrawSessionLines("London", clrLime);
    }
    else if(IsInSession(dt, NewYork))
    {
        DrawSessionLines("NewYork", clrAqua);
    }
}

//+------------------------------------------------------------------+
//| Check if current time is in session                               |
//+------------------------------------------------------------------+
bool IsInSession(MqlDateTime &dt, SessionTime &session)
{
    int currentMinutes = dt.hour * 60 + dt.min;
    int sessionStart = session.StartHour * 60 + session.StartMinute;
    int sessionEnd = session.EndHour * 60 + session.EndMinute;

    return (currentMinutes >= sessionStart && currentMinutes < sessionEnd);
}

//+------------------------------------------------------------------+
//| BUG 2: Draw session high/low lines - FULLY IMPLEMENTED            |
//+------------------------------------------------------------------+
void UpdateAndDrawSessionLines(string sessionName, color lineColor, SessionHighLow &session_hl, SessionTime &session_time)
{
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    // Check if session just started
    int currentMinutes = dt.hour * 60 + dt.min;
    int sessionStart = session_time.StartHour * 60 + session_time.StartMinute;

    if(!session_hl.IsActive || (currentMinutes == sessionStart))
    {
        // Initialize new session
        session_hl.High = iHigh(_Symbol, PERIOD_M15, 0);
        session_hl.Low = iLow(_Symbol, PERIOD_M15, 0);
        session_hl.StartTime = currentTime;
        session_hl.IsActive = true;
    }
    else
    {
        // Update running high/low
        double currentHigh = iHigh(_Symbol, PERIOD_M15, 0);
        double currentLow = iLow(_Symbol, PERIOD_M15, 0);

        if(currentHigh > session_hl.High)
            session_hl.High = currentHigh;
        if(currentLow < session_hl.Low)
            session_hl.Low = currentLow;
    }

    // Draw the high and low lines
    string highName = sessionName + "_High";
    string lowName = sessionName + "_Low";

    DrawHLine(highName, session_hl.High, lineColor, 2, STYLE_DASH);
    DrawHLine(lowName, session_hl.Low, lineColor, 2, STYLE_DASH);
}

void DrawSessionLines(string sessionName, color lineColor)
{
    if(sessionName == "Asian")
    {
        UpdateAndDrawSessionLines(sessionName, lineColor, Asian_HL, Asian);
        return;
    }

    if(sessionName == "London")
    {
        UpdateAndDrawSessionLines(sessionName, lineColor, London_HL, London);
        return;
    }

    if(sessionName == "NewYork")
    {
        UpdateAndDrawSessionLines(sessionName, lineColor, NewYork_HL, NewYork);
        return;
    }
}

//+------------------------------------------------------------------+
//| Draw RSI + Stochastic Confluence Dots                             |
//+------------------------------------------------------------------+
void DrawRSIStochDots()
{
    if(CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) <= 0) return;
    if(CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) <= 0) return;

    double rsi = RSI_M15[0];
    double stoch = Stoch_Main_M15[0];

    // Oversold confluence (buy signal)
    if(rsi < 30 && stoch < 20)
    {
        DrawDot("RSI_Stoch_Buy_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                iTime(_Symbol, PERIOD_M15, 0), iLow(_Symbol, PERIOD_M15, 0), clrLime);
    }

    // Overbought confluence (sell signal)
    if(rsi > 70 && stoch > 80)
    {
        DrawDot("RSI_Stoch_Sell_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                iTime(_Symbol, PERIOD_M15, 0), iHigh(_Symbol, PERIOD_M15, 0), clrRed);
    }
}

//+------------------------------------------------------------------+
//| Detect Candle Patterns                                            |
//+------------------------------------------------------------------+
void DetectCandlePatterns()
{
    double open0 = iOpen(_Symbol, PERIOD_M15, 0);
    double close0 = iClose(_Symbol, PERIOD_M15, 0);
    double high0 = iHigh(_Symbol, PERIOD_M15, 0);
    double low0 = iLow(_Symbol, PERIOD_M15, 0);

    double open1 = iOpen(_Symbol, PERIOD_M15, 1);
    double close1 = iClose(_Symbol, PERIOD_M15, 1);
    double high1 = iHigh(_Symbol, PERIOD_M15, 1);
    double low1 = iLow(_Symbol, PERIOD_M15, 1);

    double body0 = MathAbs(close0 - open0);
    double body1 = MathAbs(close1 - open1);

    // Bullish Engulfing
    if(close1 < open1 && close0 > open0 && close0 > open1 && open0 < close1)
    {
        DrawArrow("Bullish_Engulf_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                  iTime(_Symbol, PERIOD_M15, 0), low0, 233, clrLime);
    }

    // Bearish Engulfing
    if(close1 > open1 && close0 < open0 && close0 < open1 && open0 > close1)
    {
        DrawArrow("Bearish_Engulf_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                  iTime(_Symbol, PERIOD_M15, 0), high0, 234, clrRed);
    }

    // Pin Bar / Rejection Wick
    double upperWick = high0 - MathMax(open0, close0);
    double lowerWick = MathMin(open0, close0) - low0;

    if(lowerWick > body0 * 2)
    {
        DrawArrow("Pin_Bullish_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                  iTime(_Symbol, PERIOD_M15, 0), low0, 233, clrYellow);
    }

    if(upperWick > body0 * 2)
    {
        DrawArrow("Pin_Bearish_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                  iTime(_Symbol, PERIOD_M15, 0), high0, 234, clrOrange);
    }
}

//+------------------------------------------------------------------+
//| BUG 4: Detect Fair Value Gaps - FIXED to 15px × 15px              |
//+------------------------------------------------------------------+
void DetectFVG()
{
    double high0 = iHigh(_Symbol, PERIOD_M15, 0);
    double low0 = iLow(_Symbol, PERIOD_M15, 0);
    double high1 = iHigh(_Symbol, PERIOD_M15, 1);
    double low1 = iLow(_Symbol, PERIOD_M15, 1);
    double high2 = iHigh(_Symbol, PERIOD_M15, 2);
    double low2 = iLow(_Symbol, PERIOD_M15, 2);

    // Bullish FVG: Candle 0 low > Candle 2 high
    if(low0 > high2)
    {
        BullishFVG.Upper = low0;
        BullishFVG.Lower = high2;
        BullishFVG.Time = iTime(_Symbol, PERIOD_M15, 0);
        BullishFVG.IsBullish = true;
        BullishFVG.IsValid = true;

        // BUG 4 FIX: Draw as fixed 15px × 15px box
        double midPrice = (BullishFVG.Upper + BullishFVG.Lower) / 2.0;
        DrawFVGBox("FVG_Bullish_" + IntegerToString(BullishFVG.Time),
                   BullishFVG.Time, midPrice, clrGreen);
    }

    // Bearish FVG: Candle 0 high < Candle 2 low
    if(high0 < low2)
    {
        BearishFVG.Upper = low2;
        BearishFVG.Lower = high0;
        BearishFVG.Time = iTime(_Symbol, PERIOD_M15, 0);
        BearishFVG.IsBullish = false;
        BearishFVG.IsValid = true;

        // BUG 4 FIX: Draw as fixed 15px × 15px box
        double midPrice = (BearishFVG.Upper + BearishFVG.Lower) / 2.0;
        DrawFVGBox("FVG_Bearish_" + IntegerToString(BearishFVG.Time),
                   BearishFVG.Time, midPrice, clrRed);
    }

    // Invalidate FVG if price closes through it
    double currentClose = iClose(_Symbol, PERIOD_M15, 0);

    if(BullishFVG.IsValid && currentClose < BullishFVG.Lower)
    {
        BullishFVG.IsValid = false;
        ObjectDelete(0, "FVG_Bullish_" + IntegerToString(BullishFVG.Time));
    }

    if(BearishFVG.IsValid && currentClose > BearishFVG.Upper)
    {
        BearishFVG.IsValid = false;
        ObjectDelete(0, "FVG_Bearish_" + IntegerToString(BearishFVG.Time));
    }
}

//+------------------------------------------------------------------+
//| Draw BIAS Line                                                    |
//+------------------------------------------------------------------+
void DrawBIASLine()
{
    double close0 = iClose(_Symbol, PERIOD_M15, 0);
    double high1 = iHigh(_Symbol, PERIOD_M15, 1);
    double low1 = iLow(_Symbol, PERIOD_M15, 1);

    // Bullish BIAS: current close > previous high
    if(close0 > high1)
    {
        DrawTrendLine("BIAS_Bullish_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                      iTime(_Symbol, PERIOD_M15, 1), high1,
                      iTime(_Symbol, PERIOD_M15, 0), close0,
                      clrLime, 3, STYLE_SOLID);
    }

    // Bearish BIAS: current close < previous low
    if(close0 < low1)
    {
        DrawTrendLine("BIAS_Bearish_" + IntegerToString(iTime(_Symbol, PERIOD_M15, 0)),
                      iTime(_Symbol, PERIOD_M15, 1), low1,
                      iTime(_Symbol, PERIOD_M15, 0), close0,
                      clrRed, 3, STYLE_SOLID);
    }
}

//+------------------------------------------------------------------+
//| Detect Order Blocks                                               |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) return;
    double atr = ATR_M15[0];

    // Look for impulse moves
    double move0 = MathAbs(iClose(_Symbol, PERIOD_M15, 0) - iOpen(_Symbol, PERIOD_M15, 2));

    // Bullish Order Block: last bearish candle before bullish impulse
    if(move0 >= atr * 1.5)
    {
        double close1 = iClose(_Symbol, PERIOD_M15, 1);
        double open1 = iOpen(_Symbol, PERIOD_M15, 1);

        if(close1 < open1) // Bearish candle before impulse
        {
            BullishOB.High = iHigh(_Symbol, PERIOD_M15, 1);
            BullishOB.Low = iLow(_Symbol, PERIOD_M15, 1);
            BullishOB.Time = iTime(_Symbol, PERIOD_M15, 1);
            BullishOB.IsBullish = true;
            BullishOB.IsValid = true;

            DrawRectangle("OB_Bullish_" + IntegerToString(BullishOB.Time),
                          BullishOB.Time, BullishOB.High,
                          iTime(_Symbol, PERIOD_M15, 0) + PeriodSeconds(PERIOD_M15) * 20,
                          BullishOB.Low, clrGreen, STYLE_DOT, 2);
        }
    }

    // Bearish Order Block: last bullish candle before bearish impulse
    if(move0 >= atr * 1.5)
    {
        double close1 = iClose(_Symbol, PERIOD_M15, 1);
        double open1 = iOpen(_Symbol, PERIOD_M15, 1);

        if(close1 > open1) // Bullish candle before impulse
        {
            BearishOB.High = iHigh(_Symbol, PERIOD_M15, 1);
            BearishOB.Low = iLow(_Symbol, PERIOD_M15, 1);
            BearishOB.Time = iTime(_Symbol, PERIOD_M15, 1);
            BearishOB.IsBullish = false;
            BearishOB.IsValid = true;

            DrawRectangle("OB_Bearish_" + IntegerToString(BearishOB.Time),
                          BearishOB.Time, BearishOB.High,
                          iTime(_Symbol, PERIOD_M15, 0) + PeriodSeconds(PERIOD_M15) * 20,
                          BearishOB.Low, clrRed, STYLE_DOT, 2);
        }
    }

    // Invalidate OB if price closes through it
    double currentClose = iClose(_Symbol, PERIOD_M15, 0);

    if(BullishOB.IsValid && currentClose < BullishOB.Low)
        BullishOB.IsValid = false;

    if(BearishOB.IsValid && currentClose > BearishOB.High)
        BearishOB.IsValid = false;
}

//+------------------------------------------------------------------+
//| IDEA 3: Check Indicator Filters                                   |
//+------------------------------------------------------------------+
bool CheckIndicatorFilters(bool &isBuySignal)
{
    // Copy indicator buffers
    if(CopyBuffer(handle_ADX_M15, 0, 0, 3, ADX_Main) <= 0) return false;
    if(CopyBuffer(handle_ADX_M15, 1, 0, 3, ADX_Plus) <= 0) return false;
    if(CopyBuffer(handle_ADX_M15, 2, 0, 3, ADX_Minus) <= 0) return false;
    if(CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) <= 0) return false;
    if(CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) <= 0) return false;
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) return false;

    double adx = ADX_Main[0];
    double adx_prev = ADX_Main[1];
    double plus_di = ADX_Plus[0];
    double minus_di = ADX_Minus[0];
    double rsi = RSI_M15[0];
    double stoch = Stoch_Main_M15[0];
    double atr = ATR_M15[0];

    // ADX below 20 → no trend, block entry
    if(adx < 20)
    {
        Print("Filter blocked: ADX too low (", DoubleToString(adx, 2), ")");
        return false;
    }

    // ADX rising above 37 → trend still running, wait
    if(adx > 37 && adx > adx_prev)
    {
        Print("Filter blocked: ADX too strong and rising (", DoubleToString(adx, 2), ")");
        return false;
    }

    // ATR volatility check
    if(atr < ATR_MinThreshold || atr > ATR_MaxThreshold)
    {
        Print("Filter blocked: ATR out of range (", DoubleToString(atr, 2), ")");
        return false;
    }

    // Strong SELL signal: ADX peaked and falling, RSI > 70, Stoch > 80
    // BUG 9 FIX: Changed threshold from 30 to 37
    if(adx >= 37 && adx < adx_prev && rsi > 70 && stoch > 80)
    {
        isBuySignal = false;
        Print("Strong SELL signal confirmed by indicators");
        return true;
    }

    // Strong BUY signal: ADX peaked and falling, RSI < 30, Stoch < 20
    // BUG 9 FIX: Changed threshold from 30 to 37
    if(adx >= 37 && adx < adx_prev && rsi < 30 && stoch < 20)
    {
        isBuySignal = true;
        Print("Strong BUY signal confirmed by indicators");
        return true;
    }

    // Bullish conditions: ADX > 25, +DI > -DI, RSI/Stoch agree
    if(adx > 25 && plus_di > minus_di && rsi < 50 && stoch < 20)
    {
        isBuySignal = true;
        Print("Bullish conditions confirmed");
        return true;
    }

    // Bearish conditions: ADX > 25, -DI > +DI, RSI/Stoch agree
    if(adx > 25 && minus_di > plus_di && rsi > 50 && stoch > 80)
    {
        isBuySignal = false;
        Print("Bearish conditions confirmed");
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| IDEA 4: Protection System Checks                                  |
//+------------------------------------------------------------------+
bool PassProtectionChecks()
{
    // Check 1: Trading session hours
    if(!IsInTradingSession())
    {
        return false;
    }

    // Check 2: Max trades per day
    int maxTrades = (account.Balance() < 100) ? MaxTradesPerDay_Small : MaxTradesPerDay_Large;
    if(TradesOpenedToday >= maxTrades)
    {
        return false;
    }

    // Check 3: Spread filter
    double spread = GetCurrentSpread();
    if(spread > MaxSpread)
    {
        SpreadSpikeTime = TimeCurrent();
        CandlesSinceSpreadNormal = 0;
        return false;
    }

    // Check 4: Wait after spread spike
    if(SpreadSpikeTime > 0)
    {
        CandlesSinceSpreadNormal++;
        if(CandlesSinceSpreadNormal < SpreadCalmCandlesWait)
        {
            return false;
        }
        SpreadSpikeTime = 0;
    }

    // Check 5: News filter
    if(IsNewsTime())
    {
        return false;
    }

    // Check 6: Daily equity hard stop
    if(!CheckDailyEquityLimit())
    {
        return false;
    }

    // Check 7: ATR volatility guard
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) > 0)
    {
        double atr = ATR_M15[0];
        if(atr < ATR_MinThreshold || atr > ATR_MaxThreshold)
        {
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if in trading session                                       |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    return (IsInSession(dt, Asian) || IsInSession(dt, London) || IsInSession(dt, NewYork));
}

//+------------------------------------------------------------------+
//| Get current spread in points                                      |
//+------------------------------------------------------------------+
double GetCurrentSpread()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    return (ask - bid) / point;
}

//+------------------------------------------------------------------+
//| BUG 1: Check if news time - FULLY IMPLEMENTED                     |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
    datetime currentTime = TimeCurrent();

    // Check each loaded news event
    for(int i = 0; i < ArraySize(NewsEvents); i++)
    {
        datetime newsTime = NewsEvents[i].Time;

        // Calculate time difference in seconds
        long timeDiff = (long)(currentTime - newsTime);

        // Block window: 15 minutes before AND 15 minutes after
        long before = NewsBlockMinutesBefore * 60;
        long after = NewsBlockMinutesAfter * 60;

        // Check if we're in the blocking window
        if(timeDiff >= -before && timeDiff <= after)
        {
            Print("News block active: ", NewsEvents[i].Currency, " event at ", TimeToString(newsTime),
                  " (Current time: ", TimeToString(currentTime), ")");
            return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| Check daily equity limit + BUG 6: Drawdown protection             |
//+------------------------------------------------------------------+
bool CheckDailyEquityLimit()
{
    double currentEquity = account.Equity();
    double dailyLoss = DailyStartingEquity - currentEquity;

    double lossLimit = (account.Balance() < 100) ? DailyLossLimit_Small : (account.Balance() * 0.05);

    if(dailyLoss > lossLimit)
    {
        TradingPausedToday = true;
        Print("Daily equity loss limit reached. Trading paused for today.");
        return false;
    }

    // BUG 6: Drawdown soft cap
    double currentBalance = account.Balance();
    if(currentBalance < AccountHighWaterMark)
    {
        double drawdownPct = (AccountHighWaterMark - currentBalance) / AccountHighWaterMark * 100.0;

        // 20% drawdown → stop trading permanently until manual reset
        if(drawdownPct >= 20.0)
        {
            TradingPausedForever = true;
            Print("CRITICAL: 20% drawdown reached (", DoubleToString(drawdownPct, 2),
                  "%). Trading stopped permanently. Manual reset required.");
            return false;
        }

        // 10% drawdown → halve risk (handled in GetMaxRiskForBalance)
        if(drawdownPct >= 10.0)
        {
            Print("WARNING: 10% drawdown reached (", DoubleToString(drawdownPct, 2),
                  "%). Risk automatically halved.");
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if account is paused + BUG 6                                |
//+------------------------------------------------------------------+
bool IsAccountPaused()
{
    if(TradingPausedForever)  // BUG 6: Check permanent pause first
    {
        Print("Trading is permanently paused due to 20% drawdown");
        return true;
    }

    if(TradingPausedToday)
        return true;

    if(TimeCurrent() < PauseUntil)
        return true;

    return false;
}

//+------------------------------------------------------------------+
//| Calculate Confluence Score (0-100) for Entry Upgrade              |
//+------------------------------------------------------------------+
int CalculateConfluenceScore(bool isBuySignal)
{
    int score = 0;

    // === Trend Alignment (Max 30 points) ===
    // D1 EMA 50 trend
    if(CopyBuffer(handle_EMA50_D1, 0, 0, 1, EMA50_D1) > 0)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if((isBuySignal && currentPrice > EMA50_D1[0]) || (!isBuySignal && currentPrice < EMA50_D1[0]))
            score += 10;
    }

    // H1 EMA 200 trend
    if(CopyBuffer(handle_EMA200_H1, 0, 0, 1, EMA200_H1) > 0)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if((isBuySignal && currentPrice > EMA200_H1[0]) || (!isBuySignal && currentPrice < EMA200_H1[0]))
            score += 10;
    }

    // M15 EMA 50 trend
    if(CopyBuffer(handle_EMA50_M15, 0, 0, 1, EMA50_M15) > 0)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if((isBuySignal && currentPrice > EMA50_M15[0]) || (!isBuySignal && currentPrice < EMA50_M15[0]))
            score += 10;
    }

    // === Key Level Proximity (Max 25 points) ===
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) > 0)
    {
        double atr = ATR_M15[0];
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double tolerance = atr * 0.5;

        // Daily orange line
        if(MathAbs(currentPrice - Daily_High) <= tolerance || MathAbs(currentPrice - Daily_Low) <= tolerance)
            score += 10;

        // H1 0.68 Fib level
        if(MathAbs(currentPrice - H1_Fib_Level) <= tolerance)
            score += 8;

        // M15 0.68 Fib trendline
        if(MathAbs(currentPrice - M15_Fib_Level) <= tolerance)
            score += 7;
    }

    // === Smart Money Confirmation (Max 25 points) ===
    // Order Block
    if((isBuySignal && BullishOB.IsValid) || (!isBuySignal && BearishOB.IsValid))
        score += 10;

    // FVG
    if((isBuySignal && BullishFVG.IsValid) || (!isBuySignal && BearishFVG.IsValid))
        score += 8;

    // BIAS line
    double close0 = iClose(_Symbol, PERIOD_M15, 0);
    double high1 = iHigh(_Symbol, PERIOD_M15, 1);
    double low1 = iLow(_Symbol, PERIOD_M15, 1);
    if((isBuySignal && close0 > high1) || (!isBuySignal && close0 < low1))
        score += 4;

    // RSI+Stoch dot
    if(CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) > 0 && CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) > 0)
    {
        double rsi = RSI_M15[0];
        double stoch = Stoch_Main_M15[0];
        if((isBuySignal && rsi < 30 && stoch < 20) || (!isBuySignal && rsi > 70 && stoch > 80))
            score += 3;
    }

    // === Indicator Agreement (Max 20 points) ===
    if(CopyBuffer(handle_ADX_M15, 0, 0, 2, ADX_Main) > 0 &&
       CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) > 0 &&
       CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) > 0)
    {
        double adx = ADX_Main[0];
        double adx_prev = ADX_Main[1];
        double rsi = RSI_M15[0];
        double stoch = Stoch_Main_M15[0];

        // ADX peaked 37-40 and falling + RSI/Stoch at extreme
        if(adx >= 37 && adx <= 40 && adx < adx_prev)
        {
            if((isBuySignal && rsi < 30 && stoch < 20) || (!isBuySignal && rsi > 70 && stoch > 80))
                score += 10;
        }

        // ADX above 25 with correct DI direction
        if(CopyBuffer(handle_ADX_M15, 1, 0, 1, ADX_Plus) > 0 && CopyBuffer(handle_ADX_M15, 2, 0, 1, ADX_Minus) > 0)
        {
            double plus_di = ADX_Plus[0];
            double minus_di = ADX_Minus[0];
            if(adx > 25)
            {
                if((isBuySignal && plus_di > minus_di) || (!isBuySignal && minus_di > plus_di))
                    score += 5;
            }
        }
    }

    // Candle pattern confirmation
    double open0 = iOpen(_Symbol, PERIOD_M15, 0);
    double close0_cp = iClose(_Symbol, PERIOD_M15, 0);
    double open1 = iOpen(_Symbol, PERIOD_M15, 1);
    double close1 = iClose(_Symbol, PERIOD_M15, 1);

    // Bullish Engulfing or Pin Bar
    if(isBuySignal)
    {
        if((close1 < open1 && close0_cp > open0 && close0_cp > open1 && open0 < close1) ||
           ((MathMin(open0, close0_cp) - iLow(_Symbol, PERIOD_M15, 0)) > MathAbs(close0_cp - open0) * 2))
            score += 5;
    }
    // Bearish Engulfing or Pin Bar
    else
    {
        if((close1 > open1 && close0_cp < open0 && close0_cp < open1 && open0 > close1) ||
           ((iHigh(_Symbol, PERIOD_M15, 0) - MathMax(open0, close0_cp)) > MathAbs(close0_cp - open0) * 2))
            score += 5;
    }

    // === Time-Based Quality Filter (Bonus +5) ===
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);
    int currentMinutes = dt.hour * 60 + dt.min;

    // Check if within 30 minutes of session open
    int asianStart = Asian.StartHour * 60 + Asian.StartMinute;
    int londonStart = London.StartHour * 60 + London.StartMinute;
    int nyStart = NewYork.StartHour * 60 + NewYork.StartMinute;

    if((MathAbs(currentMinutes - asianStart) <= 30) ||
       (MathAbs(currentMinutes - londonStart) <= 30) ||
       (MathAbs(currentMinutes - nyStart) <= 30))
        score += 5;

    return score;
}

//+------------------------------------------------------------------+
//| Check for entry signals (IDEA 6) - UPGRADED                       |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
    // Step 1: Protection check
    if(!PassProtectionChecks())
        return;

    // Step 2: Indicator filter
    bool isBuySignal = false;
    if(!CheckIndicatorFilters(isBuySignal))
        return;

    // Step 3: Price near key level
    if(!IsPriceNearKeyLevel())
        return;

    // Step 4: Smart Money confirmation
    if(!HasSmartMoneyConfirmation(isBuySignal))
        return;

    // NEW: H4 EMA 200 Bias Alignment Filter
    if(CopyBuffer(handle_EMA200_H4, 0, 0, 1, EMA200_H4) > 0)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        bool aboveH4EMA = currentPrice > EMA200_H4[0];

        if(isBuySignal && !aboveH4EMA)
        {
            Print("Entry blocked: BUY signal but price below H4 EMA 200");
            return;
        }
        if(!isBuySignal && aboveH4EMA)
        {
            Print("Entry blocked: SELL signal but price above H4 EMA 200");
            return;
        }
    }

    // NEW: M5 MA 200 Filter (when on M5 timeframe)
    if(Period() == PERIOD_M5 && CopyBuffer(handle_MA200_M5, 0, 0, 1, MA200_M5) > 0)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        bool aboveM5MA = currentPrice > MA200_M5[0];

        if(isBuySignal && !aboveM5MA)
        {
            Print("Entry blocked: BUY signal but price below M5 MA 200");
            return;
        }
        if(!isBuySignal && aboveM5MA)
        {
            Print("Entry blocked: SELL signal but price above M5 MA 200");
            return;
        }
    }

    // NEW: Calculate Confluence Score
    int confluenceScore = CalculateConfluenceScore(isBuySignal);
    Print("Confluence Score: ", confluenceScore, " / 100 (Min required: 80)");

    // Minimum score check: 80 out of 100
    if(confluenceScore < 80)
    {
        Print("Entry blocked: Confluence score too low (", confluenceScore, " < 80)");
        return;
    }

    // Step 5 & 6: Execute trade
    Print("All filters passed. Confluence Score: ", confluenceScore, ". Executing trade...");
    ExecuteTrade(isBuySignal);
}

//+------------------------------------------------------------------+
//| Check if price is near key level                                  |
//+------------------------------------------------------------------+
bool IsPriceNearKeyLevel()
{
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) return false;
    double atr = ATR_M15[0];
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double tolerance = atr * 0.5;

    // Check against Daily High/Low
    if(MathAbs(currentPrice - Daily_High) <= tolerance) return true;
    if(MathAbs(currentPrice - Daily_Low) <= tolerance) return true;

    // Check against H1 Fib level
    if(MathAbs(currentPrice - H1_Fib_Level) <= tolerance) return true;

    // Check against M15 Fib level
    if(MathAbs(currentPrice - M15_Fib_Level) <= tolerance) return true;

    return false;
}

//+------------------------------------------------------------------+
//| BUG 7: Check for Smart Money confirmation - FIXED                 |
//+------------------------------------------------------------------+
bool HasSmartMoneyConfirmation(bool isBuySignal)
{
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) return false;
    double atr = ATR_M15[0];
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double tolerance = atr * 0.3;

    // Check for Order Block proximity
    if(isBuySignal && BullishOB.IsValid)
    {
        if(currentPrice >= BullishOB.Low - tolerance && currentPrice <= BullishOB.High + tolerance)
            return true;
    }

    if(!isBuySignal && BearishOB.IsValid)
    {
        if(currentPrice >= BearishOB.Low - tolerance && currentPrice <= BearishOB.High + tolerance)
            return true;
    }

    // Check for FVG
    if(isBuySignal && BullishFVG.IsValid) return true;
    if(!isBuySignal && BearishFVG.IsValid) return true;

    // Check BIAS direction
    double close0 = iClose(_Symbol, PERIOD_M15, 0);
    double high1 = iHigh(_Symbol, PERIOD_M15, 1);
    double low1 = iLow(_Symbol, PERIOD_M15, 1);

    if(isBuySignal && close0 > high1) return true;  // Bullish BIAS
    if(!isBuySignal && close0 < low1) return true;  // Bearish BIAS

    // Check RSI+Stoch dot
    if(CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) > 0 &&
       CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) > 0)
    {
        double rsi = RSI_M15[0];
        double stoch = Stoch_Main_M15[0];

        if(isBuySignal && rsi < 30 && stoch < 20) return true;
        if(!isBuySignal && rsi > 70 && stoch > 80) return true;
    }

    // BUG 7 FIX: Only return true if at least one confirmation exists
    return false;  // No confirmation found
}

//+------------------------------------------------------------------+
//| Execute trade with proper sizing and levels                       |
//+------------------------------------------------------------------+
void ExecuteTrade(bool isBuy)
{
    // Check trade frequency (aim for 1-2 trades per day)
    if(!ShouldTakeTrade())
    {
        Print("Trade frequency limit reached for today");
        return;
    }

    // Get ATR for SL/TP calculation
    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) return;
    double atr = ATR_M15[0];

    // Calculate lot size
    double lotSize = CalculateLotSize(atr);
    if(lotSize <= 0)
    {
        Print("Invalid lot size calculated");
        return;
    }

    // Get current price
    double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Calculate SL and TP
    double sl = CalculateStopLoss(isBuy, price, atr);
    double tp = CalculateTakeProfit(isBuy, price, atr);

    // Final spread check
    if(GetCurrentSpread() > MaxSpread)
    {
        Print("Final spread check failed");
        return;
    }

    // Send order
    trade.SetDeviationInPoints(MaxSlippage);

    bool result = false;
    if(isBuy)
        result = trade.Buy(lotSize, _Symbol, price, sl, tp, "XAUUSD_EA_BUY");
    else
        result = trade.Sell(lotSize, _Symbol, price, sl, tp, "XAUUSD_EA_SELL");

    if(result)
    {
        TradesOpenedToday++;
        Print("Trade opened successfully. Direction: ", isBuy ? "BUY" : "SELL",
              " | Lot: ", DoubleToString(lotSize, 2),
              " | SL: ", DoubleToString(sl, _Digits),
              " | TP: ", DoubleToString(tp, _Digits));
    }
    else
    {
        Print("Trade failed. Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| BUG 8: Check if should take trade - FIXED to use inputs           |
//+------------------------------------------------------------------+
bool ShouldTakeTrade()
{
    // BUG 8 FIX: Use input parameters instead of hardcoded value
    int maxTrades = (account.Balance() < 100) ? MaxTradesPerDay_Small : MaxTradesPerDay_Large;

    return (TradesOpenedToday < maxTrades);
}

//+------------------------------------------------------------------+
//| Calculate dynamic lot size with compounding                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double atr)
{
    double balance = account.Balance();
    double sl_pips = (atr * SL_ATR_Multiplier) / _Point;

    // Get current balance stage and risk limit
    double maxRisk = GetMaxRiskForBalance(balance);

    // Calculate lot size
    double pipValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotSize = (balance * (maxRisk / 100.0)) / (sl_pips * pipValue);

    // Normalize lot size
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return lotSize;
}

//+------------------------------------------------------------------+
//| Get max risk percentage + BUG 6: Drawdown adjustment              |
//+------------------------------------------------------------------+
double GetMaxRiskForBalance(double balance)
{
    double maxRisk = 0;

    // Progressive weekly targets adjustment
    if(UseProgressiveTargets)
    {
        double weeklyTarget = GetWeeklyTarget();

        // Adjust risk based on distance to weekly target
        if(balance < weeklyTarget * 0.5)
            maxRisk = 30.0; // Aggressive when far from target
        else if(balance < weeklyTarget * 0.8)
            maxRisk = 20.0;
        else
            maxRisk = 15.0; // Conservative near target
    }
    else
    {
        // Standard risk caps by balance stage
        if(balance < 100)
            maxRisk = 30.0; // Max $5 loss on $14-$100
        else if(balance < 500)
            maxRisk = 30.0;
        else if(balance < 2000)
            maxRisk = 20.0;
        else if(balance < 10000)
            maxRisk = 15.0;
        else if(balance < 35000)
            maxRisk = 10.0;
        else
            maxRisk = 5.0; // Near-target lock
    }

    // BUG 6: Apply drawdown reduction
    if(balance < AccountHighWaterMark)
    {
        double drawdownPct = (AccountHighWaterMark - balance) / AccountHighWaterMark * 100.0;

        // 10% drawdown → halve risk
        if(drawdownPct >= 10.0)
        {
            maxRisk = maxRisk * 0.5;
            Print("Risk halved due to ", DoubleToString(drawdownPct, 2), "% drawdown. New risk: ", DoubleToString(maxRisk, 2), "%");
        }
    }

    return maxRisk;
}

//+------------------------------------------------------------------+
//| Get current weekly target                                         |
//+------------------------------------------------------------------+
double GetWeeklyTarget()
{
    switch(CurrentWeek)
    {
        case 1: return Week1_Target;
        case 2: return Week2_Target;
        case 3: return Week3_Target;
        case 4: return Week4_Target;
        case 5: return Week5_Target;
        case 6: return Week6_Target;
        case 7: return Week7_Target;
        case 8: return Week8_Target;
        case 9: return Week9_Target;
        default: return FinalTarget;
    }
}

//+------------------------------------------------------------------+
//| Calculate stop loss                                               |
//+------------------------------------------------------------------+
double CalculateStopLoss(bool isBuy, double entryPrice, double atr)
{
    double sl_distance = atr * SL_ATR_Multiplier;

    // Apply minimum SL based on timeframe
    ENUM_TIMEFRAMES tf = Period();
    double minSL_pips = (tf <= PERIOD_M5) ? MinSL_M1M5_Pips : MinSL_M15_Pips;
    double maxSL_pips = (tf <= PERIOD_M5) ? MaxSL_M1M5_Pips : MaxSL_M15_Pips;

    double minSL_price = minSL_pips * _Point * 10; // Convert pips to price
    double maxSL_price = maxSL_pips * _Point * 10;

    sl_distance = MathMax(sl_distance, minSL_price);
    sl_distance = MathMin(sl_distance, maxSL_price);

    double sl = isBuy ? entryPrice - sl_distance : entryPrice + sl_distance;

    return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
//| Calculate take profit                                             |
//+------------------------------------------------------------------+
double CalculateTakeProfit(bool isBuy, double entryPrice, double atr)
{
    // First try to use nearest key level
    double tp = GetNearestKeyLevel(isBuy, entryPrice);

    // If no key level in range, use ATR-based TP
    if(tp == 0)
    {
        double tp_distance = atr * TP_ATR_Multiplier;
        tp = isBuy ? entryPrice + tp_distance : entryPrice - tp_distance;
    }

    return NormalizeDouble(tp, _Digits);
}

//+------------------------------------------------------------------+
//| Get nearest key level for TP                                      |
//+------------------------------------------------------------------+
double GetNearestKeyLevel(bool isBuy, double entryPrice)
{
    double nearest = 0;
    double minDistance = DBL_MAX;

    // Check all key levels
    double levels[] = {Daily_High, Daily_Low, H1_Fib_Level, M15_Fib_Level};

    for(int i = 0; i < ArraySize(levels); i++)
    {
        if(levels[i] == 0) continue;

        double distance = isBuy ? (levels[i] - entryPrice) : (entryPrice - levels[i]);

        if(distance > 0 && distance < minDistance)
        {
            minDistance = distance;
            nearest = levels[i];
        }
    }

    return nearest;
}

//+------------------------------------------------------------------+
//| Manage open positions (trailing stop, breakeven, partial close)   |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!position.SelectByIndex(i)) continue;
        if(position.Symbol() != _Symbol) continue;

        ulong ticket = position.Ticket();
        double openPrice = position.PriceOpen();
        double currentSL = position.StopLoss();
        double currentTP = position.TakeProfit();
        bool isBuy = (position.Type() == POSITION_TYPE_BUY);

        double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) <= 0) continue;
        double atr = ATR_M15[0];

        double profit = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);

        // Breakeven rule
        if(profit >= atr * Breakeven_ATR_Trigger && currentSL != openPrice)
        {
            trade.PositionModify(ticket, openPrice, currentTP);
            Print("Position ", ticket, " moved to breakeven");
            continue;
        }

        // Trailing stop
        if(profit >= atr * 0.5)
        {
            double trailDistance = MathMax(20 * _Point, atr * Trailing_ATR_Multiplier);
            double newSL = isBuy ? (currentPrice - trailDistance) : (currentPrice + trailDistance);

            // Only move SL forward
            if((isBuy && newSL > currentSL) || (!isBuy && newSL < currentSL))
            {
                // Check if change is significant enough
                if(MathAbs(newSL - currentSL) >= atr * 0.5)
                {
                    trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), currentTP);
                    Print("Trailing stop updated for position ", ticket);
                }
            }
        }

        // Partial close at first key level
        if(IsAtKeyLevel(currentPrice))
        {
            double currentVolume = position.Volume();
            double closeVolume = NormalizeDouble(currentVolume * (PartialClosePercent / 100.0), 2);

            if(closeVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
            {
                trade.PositionClosePartial(ticket, closeVolume);
                Print("Partial close executed for position ", ticket, " | Volume: ", closeVolume);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check if price is at a key level                                  |
//+------------------------------------------------------------------+
bool IsAtKeyLevel(double price)
{
    double tolerance = 10 * _Point; // Small tolerance

    if(MathAbs(price - Daily_High) <= tolerance) return true;
    if(MathAbs(price - Daily_Low) <= tolerance) return true;
    if(MathAbs(price - H1_Fib_Level) <= tolerance) return true;
    if(MathAbs(price - M15_Fib_Level) <= tolerance) return true;

    return false;
}

//+------------------------------------------------------------------+
//| Create Modern UI Panel (2027 Standards)                           |
//+------------------------------------------------------------------+
void CreateUI()
{
    int panelWidth = 300;
    int panelHeight = 400;
    int x = UI_X_Offset;
    int y = UI_Y_Offset;
    int lineHeight = 20;

    // Create main panel background
    ObjectCreate(0, UI_Panel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, UI_Panel, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, UI_Panel, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, UI_Panel, OBJPROP_XSIZE, panelWidth);
    ObjectSetInteger(0, UI_Panel, OBJPROP_YSIZE, panelHeight);
    ObjectSetInteger(0, UI_Panel, OBJPROP_CORNER, UI_Corner);
    ObjectSetInteger(0, UI_Panel, OBJPROP_COLOR, UI_BackgroundColor);
    ObjectSetInteger(0, UI_Panel, OBJPROP_BGCOLOR, UI_BackgroundColor);
    ObjectSetInteger(0, UI_Panel, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, UI_Panel, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, UI_Panel, OBJPROP_BACK, true);

    // Create labels
    CreateLabel(UI_Label_Prefix + "Title", x + 10, y + 10, "XAUUSD Gold EA v1.0", clrGold, 12, true);
    CreateLabel(UI_Label_Prefix + "Balance", x + 10, y + 40, "Balance: $0.00", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Equity", x + 10, y + 60, "Equity: $0.00", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Week", x + 10, y + 80, "Week: 1", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Target", x + 10, y + 100, "Target: $100.00", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Progress", x + 10, y + 120, "Progress: 0%", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "TodayTrades", x + 10, y + 150, "Today's Trades: 0", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "OpenPos", x + 10, y + 170, "Open Positions: 0", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Status", x + 10, y + 200, "Status: Active", clrLime, 10, true);
    CreateLabel(UI_Label_Prefix + "ADX", x + 10, y + 230, "ADX: 0.0", UI_TextColor, 9);
    CreateLabel(UI_Label_Prefix + "RSI", x + 10, y + 250, "RSI: 0.0", UI_TextColor, 9);
    CreateLabel(UI_Label_Prefix + "Stoch", x + 10, y + 270, "Stoch: 0.0", UI_TextColor, 9);
    CreateLabel(UI_Label_Prefix + "ATR", x + 10, y + 290, "ATR: 0.0", UI_TextColor, 9);
    CreateLabel(UI_Label_Prefix + "Spread", x + 10, y + 310, "Spread: 0.0", UI_TextColor, 9);
    CreateLabel(UI_Label_Prefix + "Session", x + 10, y + 340, "Session: None", UI_TextColor, 10);
    CreateLabel(UI_Label_Prefix + "Footer", x + 10, y + 370, "© 2027 Advanced Trading System", clrDimGray, 8);
}

//+------------------------------------------------------------------+
//| Create a label on the chart                                       |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold = false)
{
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_CORNER, UI_Corner);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Black" : "Arial");
    ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| Update UI with current data                                       |
//+------------------------------------------------------------------+
void UpdateUI()
{
    double balance = account.Balance();
    double equity = account.Equity();
    double weeklyTarget = GetWeeklyTarget();
    double progress = (balance / weeklyTarget) * 100.0;

    ObjectSetString(0, UI_Label_Prefix + "Balance", OBJPROP_TEXT,
                    "Balance: $" + DoubleToString(balance, 2));
    ObjectSetString(0, UI_Label_Prefix + "Equity", OBJPROP_TEXT,
                    "Equity: $" + DoubleToString(equity, 2));
    ObjectSetString(0, UI_Label_Prefix + "Week", OBJPROP_TEXT,
                    "Week: " + IntegerToString(CurrentWeek));
    ObjectSetString(0, UI_Label_Prefix + "Target", OBJPROP_TEXT,
                    "Target: $" + DoubleToString(weeklyTarget, 2));
    ObjectSetString(0, UI_Label_Prefix + "Progress", OBJPROP_TEXT,
                    "Progress: " + DoubleToString(progress, 1) + "%");
    ObjectSetString(0, UI_Label_Prefix + "TodayTrades", OBJPROP_TEXT,
                    "Today's Trades: " + IntegerToString(TradesOpenedToday));
    ObjectSetString(0, UI_Label_Prefix + "OpenPos", OBJPROP_TEXT,
                    "Open Positions: " + IntegerToString(PositionsTotal()));

    // Status
    string status = "Active";
    color statusColor = clrLime;
    if(IsAccountPaused())
    {
        status = "Paused";
        statusColor = clrRed;
    }
    else if(!IsInTradingSession())
    {
        status = "Out of Session";
        statusColor = clrYellow;
    }

    ObjectSetString(0, UI_Label_Prefix + "Status", OBJPROP_TEXT, "Status: " + status);
    ObjectSetInteger(0, UI_Label_Prefix + "Status", OBJPROP_COLOR, statusColor);

    // Indicators
    if(CopyBuffer(handle_ADX_M15, 0, 0, 1, ADX_Main) > 0)
        ObjectSetString(0, UI_Label_Prefix + "ADX", OBJPROP_TEXT,
                        "ADX: " + DoubleToString(ADX_Main[0], 1));

    if(CopyBuffer(handle_RSI_M15, 0, 0, 1, RSI_M15) > 0)
        ObjectSetString(0, UI_Label_Prefix + "RSI", OBJPROP_TEXT,
                        "RSI: " + DoubleToString(RSI_M15[0], 1));

    if(CopyBuffer(handle_Stoch_M15, 0, 0, 1, Stoch_Main_M15) > 0)
        ObjectSetString(0, UI_Label_Prefix + "Stoch", OBJPROP_TEXT,
                        "Stoch: " + DoubleToString(Stoch_Main_M15[0], 1));

    if(CopyBuffer(handle_ATR_M15, 0, 0, 1, ATR_M15) > 0)
        ObjectSetString(0, UI_Label_Prefix + "ATR", OBJPROP_TEXT,
                        "ATR: " + DoubleToString(ATR_M15[0], 1));

    ObjectSetString(0, UI_Label_Prefix + "Spread", OBJPROP_TEXT,
                    "Spread: " + DoubleToString(GetCurrentSpread(), 1));

    // Session
    string sessionName = GetCurrentSessionName();
    ObjectSetString(0, UI_Label_Prefix + "Session", OBJPROP_TEXT,
                    "Session: " + sessionName);
}

//+------------------------------------------------------------------+
//| Get current session name                                          |
//+------------------------------------------------------------------+
string GetCurrentSessionName()
{
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    if(IsInSession(dt, Asian)) return "Asian";
    if(IsInSession(dt, London)) return "London";
    if(IsInSession(dt, NewYork)) return "New York";

    return "None";
}

//+------------------------------------------------------------------+
//| Delete UI                                                          |
//+------------------------------------------------------------------+
void DeleteUI()
{
    ObjectDelete(0, UI_Panel);

    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, UI_Label_Prefix) >= 0)
            ObjectDelete(0, name);
    }
}

//+------------------------------------------------------------------+
//| Delete all chart objects created by EA                            |
//+------------------------------------------------------------------+
void DeleteAllObjects()
{
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, "Daily_") >= 0 ||
           StringFind(name, "H1_") >= 0 ||
           StringFind(name, "M15_") >= 0 ||
           StringFind(name, "RSI_") >= 0 ||
           StringFind(name, "FVG_") >= 0 ||
           StringFind(name, "OB_") >= 0 ||
           StringFind(name, "BIAS_") >= 0 ||
           StringFind(name, "Pin_") >= 0 ||
           StringFind(name, "Bullish_") >= 0 ||
           StringFind(name, "Bearish_") >= 0)
        {
            ObjectDelete(0, name);
        }
    }
}

//+------------------------------------------------------------------+
//| Helper: Draw horizontal line                                      |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, int width, ENUM_LINE_STYLE style)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
}

//+------------------------------------------------------------------+
//| Helper: Draw trend line                                           |
//+------------------------------------------------------------------+
void DrawTrendLine(string name, datetime time1, double price1, datetime time2, double price2,
                   color clr, int width, ENUM_LINE_STYLE style)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_TREND, 0, time1, price1, time2, price2);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
}

//+------------------------------------------------------------------+
//| Helper: Draw rectangle                                            |
//+------------------------------------------------------------------+
void DrawRectangle(string name, datetime time1, double price1, datetime time2, double price2,
                   color clr, ENUM_LINE_STYLE style, int width)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price1, time2, price2);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    ObjectSetInteger(0, name, OBJPROP_BACK, true);
    ObjectSetInteger(0, name, OBJPROP_FILL, true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Helper: Draw arrow                                                |
//+------------------------------------------------------------------+
void DrawArrow(string name, datetime time, double price, int arrowCode, color clr)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrowCode);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Helper: Draw dot                                                  |
//+------------------------------------------------------------------+
void DrawDot(string name, datetime time, double price, color clr)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159); // Small dot
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| BUG 4: Helper: Draw FVG box as fixed 15px × 15px                  |
//+------------------------------------------------------------------+
void DrawFVGBox(string name, datetime time, double price, color clr)
{
    if(ObjectFind(0, name) >= 0)
        ObjectDelete(0, name);

    // Create rectangle label (fixed pixel size)
    ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

    // Set position based on time and price
    int x, y;
    if(ChartTimePriceToXY(0, 0, time, price, x, y))
    {
        ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    }

    // Set fixed size: 15px × 15px
    ObjectSetInteger(0, name, OBJPROP_XSIZE, 15);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, 15);

    // Set colors and style
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| BUG 3: Draw M5 White 200 MA                                       |
//+------------------------------------------------------------------+
void DrawM5_MA200()
{
    // Only draw on M5 timeframe
    if(Period() != PERIOD_M5)
        return;

    if(CopyBuffer(handle_MA200_M5, 0, 0, 1, MA200_M5) <= 0)
        return;

    // Draw MA as white line - current value
    string name = "M5_MA200_Line";
    double ma_value = MA200_M5[0];

    DrawHLine(name, ma_value, clrWhite, 3, STYLE_SOLID);
}

//+------------------------------------------------------------------+
