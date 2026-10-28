###############################################################################
# Block 1 : Imports
###############################################################################
import sys, time, os, json, joblib
from tkinter import ROUND
from datetime import datetime, timedelta
from typing import Dict, Any, Tuple, Optional
import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import requests
from sklearn.linear_model import LogisticRegression
import warnings

if sys.version_info >= (3, 12):
    print(f"{datetime.now()}: WARNING – MetaTrader5 wheels exist only for "
          f"Python ≤ 3.11; you are on {sys.version.split()[0]}", flush=True)
###############################################################################
# Block 2 : User settings
###############################################################################
LOGIN, PASSWORD, SERVER = 263239369, "Admin&@12345", "Exness-MT5Real37"
SYMBOL         = "XAUUSDm"                # Trading instrument
TF_ENTRY       = mt5.TIMEFRAME_M1         #M5 Timeframe for entry signals
TF_TREND       = mt5.TIMEFRAME_M15        #H1 Timeframe for trend confirmation
EMA_PERIOD     = 8                        #16,22 Period for the Exponential Moving Average
RSI_PERIOD     = 12                       #14 Period for the Relative Strength Index
LOT_SIZE       = 0.01                     # Trade volume in lots
RR_RATIO       = 2.0                      #2 Risk/Reward ratio for TP
SL_ATR_MULTI   = 2.2                      #2 Multiplier for ATR-based Stop Loss
THRESHOLD       = 0.60    # Trade only if P(win) >= 60 %
WARMUP_TRADES   = 30      #30 First 30 trades are always executed to gather data
BASE_DIR   = r"C:\Desktop\XAU"
SYMBOL_DIR = os.path.join(BASE_DIR, SYMBOL)
os.makedirs(SYMBOL_DIR, exist_ok=True)
FEATURE_FILE = os.path.join(SYMBOL_DIR, "features_22-25.csv") # Switched to CSV for easier handling
MODEL_FILE   = os.path.join(SYMBOL_DIR, "lr_model_22-25.joblib")
SETTING_FILE = os.path.join(BASE_DIR, "setting_22-25.csv")
RETRAIN_EVERY = 8           # Retrain after this many closed trades
LOOP_SECONDS  = 10          # 10s loop cadence

TIME_BETWEEN_TRADES = 300   #300s in between trades

SL_BE_DIFFERENCE = 2        # After how many points stop loss will be adjusted to break even
SL_ENTRY_DIFFERENCE = 3     # After how many points stop loss will be adjusted to first TP
SL_TP_DIFFERENCE = 3        # After how many points stop loss will be adjusted to next TP

SLTP_ADJUST = 0.5           # How many point to adjust SL TP by

MAGIC_NO_1 = 22000
MAGIC_NO_2 = 23000
MAGIC_NO_3 = 24000
MAGIC_NO_4 = 25000

# ========================
# Betting hours (local time)
# ========================
BETTING_START = 0    # Start trading at 08:00 local time (inclusive)
BETTING_END = 23     # Stop trading at 19:00 local time (exclusive)

def send_telegram_message(message: str):
    bot_token = ""
    chat_id = ""
    if not bot_token or not chat_id:
        return
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    try:
        requests.post(url, data={"chat_id": chat_id, "text": message})
    except Exception as e:
        print(f"Telegram exception: {e}")

def save_settings(old_settings: dict, new_settings: dict, trade_count: int, model: Optional[LogisticRegression]):
    """Appends old/new settings and model params to setting.csv for audit trail."""
    import csv

    # Prepare model coefficients and intercept for logging
    if model is not None:
        coef = model.coef_[0] if hasattr(model, "coef_") else []
        intercept = model.intercept_[0] if hasattr(model, "intercept_") else 0
    else:
        coef = []
        intercept = 0
    row = {
        "timestamp": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "trade_count": trade_count,
        "old_settings": json.dumps(old_settings),
        "new_settings": json.dumps(new_settings),
        "model_coef": json.dumps(coef.tolist() if hasattr(coef, 'tolist') else list(coef)),
        "model_intercept": intercept
    }
    write_header = not os.path.isfile(SETTING_FILE)
    with open(SETTING_FILE, 'a', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=row.keys())
        if write_header:
            writer.writeheader()
        writer.writerow(row)

def current_settings_dict():
    """Return a dict of all current key settings for tracking."""
    return {
        "LOGIN": LOGIN,
        "SERVER": SERVER,
        "SYMBOL": SYMBOL,
        "TF_ENTRY": TF_ENTRY,
        "TF_TREND": TF_TREND,
        "EMA_PERIOD": EMA_PERIOD,
        "RSI_PERIOD": RSI_PERIOD,
        "LOT_SIZE": LOT_SIZE,
        "RR_RATIO": RR_RATIO,
        "SL_ATR_MULTI": SL_ATR_MULTI,
        "THRESHOLD": THRESHOLD,
        "WARMUP_TRADES": WARMUP_TRADES,
        "RETRAIN_EVERY": RETRAIN_EVERY,
        "BETTING_START": BETTING_START,
        "BETTING_END": BETTING_END,
        "LOOP_SECONDS": LOOP_SECONDS,
    }

###############################################################################
# Block 3 : Strategy & feature engineering
###############################################################################
def fetch_rates(timeframe: int, bars: int = 500) -> pd.DataFrame:
    """Fetches historical data from MetaTrader 5."""
    rates = mt5.copy_rates_from_pos(SYMBOL, timeframe, 0, bars)
    return pd.DataFrame(rates) if rates is not None else pd.DataFrame()
def indicator_pack(df: pd.DataFrame) -> pd.DataFrame:
    """Calculates and adds technical indicators to the dataframe."""
    if df.empty:
        return df
    
    # Exponential Moving Average (EMA)
    df["ema"] = df["close"].ewm(span=EMA_PERIOD, adjust=False).mean()
    # Average True Range (ATR)
    hl = df["high"] - df["low"]
    hc = (df["high"] - df["close"].shift()).abs()
    lc = (df["low"]  - df["close"].shift()).abs()
    tr = pd.concat([hl, hc, lc], axis=1).max(axis=1)
    df["atr"] = tr.rolling(14).mean()
    # Average Directional Index (ADX)
    up, dn = df["high"].diff(), -df["low"].diff()
    plus_dm  = np.where((up > dn) & (up > 0), up, 0.)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.)
    tr14     = tr.rolling(14).sum()
    plus_di  = 100 * pd.Series(plus_dm).rolling(14).sum() / tr14
    minus_di = 100 * pd.Series(minus_dm).rolling(14).sum() / tr14
    dx       = (abs(plus_di - minus_di) / (plus_di + minus_di)).replace([np.inf, -np.inf], 0).fillna(0) * 100
    df["adx"] = dx.rolling(14).mean()
    # Relative Strength Index (RSI)
    delta = df["close"].diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=RSI_PERIOD).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=RSI_PERIOD).mean()
    rs = gain / loss
    df["rsi"] = 100 - (100 / (1 + rs))
    
    return df
def get_trade_signal() -> Tuple[Optional[str], Dict[str, bool], Optional[pd.Series], Optional[pd.Series], Optional[float]]:
    """
    Checks trading conditions and returns a signal along with filter progress.
    Now includes RSI as a filter!
    """
    entry_df = indicator_pack(fetch_rates(TF_ENTRY, 300))
    trend_df = indicator_pack(fetch_rates(TF_TREND, 300))
    if entry_df.empty or trend_df.empty or len(entry_df) < 2:
        return None, {}, None, None, None  # Return if data feed has issues
    last, prev = entry_df.iloc[-1], entry_df.iloc[-2]
    trend_last = trend_df.iloc[-1]
    atr_median = entry_df["atr"].median()
    # --- Filter Conditions ---
    rsi_min, rsi_max = 30, 70
    buy_filters = {
        "Crossed Up": prev.close < prev.ema and last.close > last.ema,
        "Trend Up": trend_last.close > trend_last.ema,
        "AVG True Range OK": last.atr > atr_median,
        "AVG Dir Index OK": last.adx > 20,
        "Rel Strength Index OK": rsi_min < last.rsi < rsi_max
    }
    sell_filters = {
        "Crossed Down": prev.close > prev.ema and last.close < last.ema,
        "Trend Down": trend_last.close < trend_last.ema,
        "AVG True Range OK": last.atr > atr_median,
        "AVG Dir Index OK": last.adx > 20,
        "Rel Strength Index OK": rsi_min < last.rsi < rsi_max
    }
    # --- Logging Filter Progress ---
    print(f"{datetime.now()}: BUY filter progress:")
    for key, value in buy_filters.items():
        print(f"  {'✓' if value else '✗'} {key}: {value}")
    print(f"{sum(buy_filters.values())}/{len(buy_filters)} filters passed for BUY")
    print(f"{datetime.now()}: SELL filter progress:")
    for key, value in sell_filters.items():
        print(f"  {'✓' if value else '✗'} {key}: {value}")
    print(f"{sum(sell_filters.values())}/{len(sell_filters)} filters passed for SELL")
    # --- Determine Signal ---
    if all(buy_filters.values()):
        return "BUY", buy_filters, last, trend_last, atr_median
    if all(sell_filters.values()):
        return "SELL", sell_filters, last, trend_last, atr_median
    
    # Return BUY or SELL filter progress based on which had more signals, for context
    filters = buy_filters if sum(buy_filters.values()) > sum(sell_filters.values()) else sell_filters
    return None, filters, last, trend_last, atr_median
def build_features(candle: pd.Series, trend_candle: pd.Series, atr_median: float) -> Dict[str, Any]:
    """Constructs a feature dictionary for a given candle."""
    return {
        "timestamp": int(candle.time),
        "hour": datetime.fromtimestamp(candle.time).hour,
        "candle_size": candle.high - candle.low,
        "ema_distance": abs(candle.close - candle.ema),
        "atr": candle.atr,
        "adx": candle.adx,
        "rsi": candle.rsi,
        "volume": candle.tick_volume,
        "trend_above_ema": int(trend_candle.close > trend_candle.ema),
        "range_status": int(candle.adx < 20),
        "volatility_level": int(candle.atr > atr_median),
        "outcome": -1,  # Default: -1=pending, 0=loss, 1=win
        "entered": 0,
        "had_signal": 0,
    }
###############################################################################
# Block 4 : Learning engine
###############################################################################
def load_dataset() -> pd.DataFrame:
    """Loads the feature dataset from a CSV file and ensures required columns exist."""
    columns = [
        "timestamp", "hour", "candle_size", "ema_distance", "atr", "adx",
        "rsi", "volume", "trend_above_ema", "range_status",
        "volatility_level", "outcome", "entered", "had_signal"
    ]
    if not os.path.isfile(FEATURE_FILE):
        return pd.DataFrame(columns=columns)
    df = pd.read_csv(FEATURE_FILE)
    # Add any missing columns (for backward compatibility)
    for col in columns:
        if col not in df.columns:
            df[col] = -1 if col == "outcome" else 0
    return df
def save_dataset(df: pd.DataFrame):
    """Saves the entire dataset back to the CSV file."""
    df.to_csv(FEATURE_FILE, index=False)
def train_model(df: pd.DataFrame) -> Optional[LogisticRegression]:
    """Trains and saves the logistic regression model."""
    feature_cols = ["hour", "candle_size", "ema_distance", "atr", "adx", "rsi",
                    "volume", "trend_above_ema", "range_status", "volatility_level"]
    
    # Debug: Check what's in the outcome column
    print(f"Unique outcome values before filtering: {df['outcome'].unique()}")
    print(f"Outcome dtype: {df['outcome'].dtype}")
    
    # Ensure outcome column is numeric and handle any issues
    df['outcome'] = pd.to_numeric(df['outcome'], errors='coerce')
    
    # Train only on trades that have concluded (win or loss)
    # Filter for EXACTLY 0 or 1 (not -1, not NaN, not floats)
    trades = df[df['outcome'].isin([0, 1])].copy()
    
    # Extra safety: ensure outcomes are integers
    trades['outcome'] = trades['outcome'].astype(int)
    
    print(f"Unique outcome values after filtering: {trades['outcome'].unique()}")
    print(f"Number of wins: {(trades['outcome'] == 1).sum()}")
    print(f"Number of losses: {(trades['outcome'] == 0).sum()}")
    
    if len(trades) < WARMUP_TRADES:
        print(f"{datetime.now()}: Not enough completed trades ({len(trades)}) to train. Need {WARMUP_TRADES}.")
        return None
    
    # Check if we have both classes (0 and 1)
    if len(trades['outcome'].unique()) < 2:
        print(f"WARNING: Only one outcome class found: {trades['outcome'].unique()}")
        print(f"Need both wins and losses to train. Skipping training.")
        return None
    
    # Check for missing features
    missing_features = [col for col in feature_cols if col not in trades.columns]
    if missing_features:
        print(f"ERROR: Missing features in dataframe: {missing_features}")
        return None
    
    # Handle any NaN values in features
    if trades[feature_cols].isnull().any().any():
        print("WARNING: NaN values detected in features. Filling with 0.")
        trades[feature_cols] = trades[feature_cols].fillna(0)
    
    # Ensure all features are numeric
    for col in feature_cols:
        trades[col] = pd.to_numeric(trades[col], errors='coerce').fillna(0)
    
    try:
        X, y = trades[feature_cols], trades["outcome"]
        
        print(f"Training model with {len(trades)} samples...")
        print(f"Features shape: {X.shape}")
        print(f"Outcomes shape: {y.shape}")
        
        model = LogisticRegression(max_iter=500, class_weight='balanced').fit(X, y)
        joblib.dump(model, MODEL_FILE)
        
        # Print model performance
        train_score = model.score(X, y)
        print(f"Model training accuracy: {train_score:.2%}")
        
        return model
        
    except Exception as e:
        print(f"ERROR during model training: {e}")
        print(f"X dtypes: {X.dtypes.to_dict()}")
        print(f"y dtype: {y.dtype}")
        print(f"First few y values: {y.head(10).tolist()}")
        return None
def get_model() -> Optional[LogisticRegression]:
    """Loads a pre-trained model from disk."""
    return joblib.load(MODEL_FILE) if os.path.isfile(MODEL_FILE) else None

def clean_dataset(df):
    """
    Clean the dataset to ensure proper data types and values
    Call this once after loading your dataset
    """
    print("Cleaning dataset...")
    
    # 1. Ensure outcome column exists and is numeric
    if 'outcome' in df.columns:
        # Convert to numeric, replacing any non-numeric with NaN
        df['outcome'] = pd.to_numeric(df['outcome'], errors='coerce')
        
        # Check for any float outcomes that should be int
        mask_float_outcomes = df['outcome'].isin([0.0, 1.0])
        if mask_float_outcomes.any():
            df.loc[mask_float_outcomes, 'outcome'] = df.loc[mask_float_outcomes, 'outcome'].astype(int)
            print(f"Converted {mask_float_outcomes.sum()} float outcomes to int")
        
        # Report on outcome values
        print(f"Outcome value counts:")
        print(df['outcome'].value_counts().sort_index())
        
        # Check for invalid outcomes (not -1, 0, or 1)
        invalid_mask = ~df['outcome'].isin([-1, 0, 1]) & df['outcome'].notna()
        if invalid_mask.any():
            print(f"WARNING: Found {invalid_mask.sum()} rows with invalid outcomes")
            print(f"Invalid outcome values: {df.loc[invalid_mask, 'outcome'].unique()}")
            # Set invalid outcomes to -1 (pending)
            df.loc[invalid_mask, 'outcome'] = -1
    
    # 2. Ensure all feature columns are numeric
    feature_cols = ["hour", "candle_size", "ema_distance", "atr", "adx", "rsi",
                    "volume", "trend_above_ema", "range_status", "volatility_level"]
    
    for col in feature_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
    
    # 3. Ensure timestamp is datetime
    if 'timestamp' in df.columns:
        df['timestamp'] = pd.to_datetime(df['timestamp'], errors='coerce')
        
        # Remove rows with invalid timestamps
        invalid_timestamps = df['timestamp'].isna()
        if invalid_timestamps.any():
            print(f"Removing {invalid_timestamps.sum()} rows with invalid timestamps")
            df = df[~invalid_timestamps]
    
    print(f"Dataset cleaned. Total rows: {len(df)}")
    print(f"Pending trades: {(df['outcome'] == -1).sum()}")
    print(f"Completed trades: {df['outcome'].isin([0, 1]).sum()}")
    print(f"Wins: {(df['outcome'] == 1).sum()}")
    print(f"Losses: {(df['outcome'] == 0).sum()}")
    
    return df

###############################################################################
# Block 4.5 : Robust Open Position Check
###############################################################################
def has_open_position(symbol, magic):
    """Check with MT5 if there's any open position for this symbol and magic number."""
    positions = mt5.positions_get(symbol=symbol)
    if positions is None:
        return False  # Treat as no position in case of error
    for pos in positions:
        if pos.magic == magic:
            return True
    return False

###############################################################################
# Block 4.55 : Sync Existing Positions
###############################################################################
def sync_existing_position():
    print("Syncing existing open positions...")
    positions = mt5.positions_get()
    if positions:
        for pos in positions:
            position_id = pos.identifier
            if position_id not in open_trades:
                # Found untracked position, add it
                signal_timestamp = pd.Timestamp.fromtimestamp(pos.time)
                open_trades[position_id] = signal_timestamp
                print(f"Found existing position {position_id}, added to tracking", flush=True)
                
                # Check if this position has a signal in the dataframe
                mask = (df['timestamp'] - signal_timestamp).abs() <= pd.Timedelta(seconds=60)
                if not mask.any() or (df.loc[mask, 'outcome'] != -1).all():
                    # No matching pending signal, add one
                    new_row = {
                        'timestamp': signal_timestamp,
                        'outcome': -1,  # Pending
                        'hour': signal_timestamp.hour,
                        'candle_size': 0,
                        'ema_distance': 0,
                        'atr': 0,
                        'adx': 25,
                        'rsi': 50,
                        'volume': pos.volume,
                        'trend_above_ema': 0,
                        'range_status': 0,
                        'volatility_level': 0,
                    }
                    df.loc[len(df)] = new_row
                    print(f"Added signal row for existing position {position_id}", flush=True)
                    save_dataset(df)
    
    print(f"Startup sync complete. Tracking {len(open_trades)} positions")


###############################################################################
# Block 4.6 : Send order
###############################################################################
def send_order(order_type,price,sl_value,tp_value,magic_no,signal):
      request = {
          "action": mt5.TRADE_ACTION_DEAL,
          "symbol": SYMBOL,
          "volume": LOT_SIZE,
          "type": order_type,
          "price": price,
          "sl": sl_value,
          "tp": tp_value,
          "deviation": 20,
          "magic": magic_no, # Use a magic number to identify trades from this bot
      }

      signal_timestamp = datetime.now()

      result = mt5.order_send(request)
      if result.retcode == mt5.TRADE_RETCODE_DONE:
           ticket = result.order
           print(f"Order placed, ticket: {ticket}", flush=True)
           
           # CRITICAL: Get the POSITION ID, not the ticket!
           time.sleep(1)  # Wait for position to register
           
           # Get positions for the symbol you just traded
           positions = mt5.positions_get(symbol=SYMBOL)  # Use your symbol variable
           if positions:
               # Find the newest position (highest identifier)
               newest_position = max(positions, key=lambda p: p.identifier)
               position_id = newest_position.identifier
               
               print(f"Position opened with ID: {position_id} (order ticket was {ticket})", flush=True)
               
               # Store by POSITION ID, not ticket!
               open_trades[position_id] = signal_timestamp  # <-- NEW WAY
           else:
               print(f"ERROR: Could not find position after placing order {ticket}", flush=True)


           print(f"{now}: {signal} ticket={result.order} prob={prob:.2%}", flush=True)
           msg = (f"{signal} trade opened with\nSL:{round((sl_value),1)}\nTP:{round((tp_value),1)}\n"
                  f"{now}")                        
           send_telegram_message(msg)
      else:
          print(f"{now}: Order send failed, retcode={result.retcode}", flush=True)   

###############################################################################
# Block 4.7 : Order adjust
###############################################################################
def order_check_adjust(ticket,new_sl,new_tp,magic_no):
      request = {
          "action": mt5.TRADE_ACTION_SLTP,
          "symbol": SYMBOL,
          "position": ticket,
          "sl": new_sl,
          "tp": new_tp,
          "deviation": 20,
          "magic": magic_no,
      }
      
      result = mt5.order_send(request)
      if result.retcode == mt5.TRADE_RETCODE_DONE:
          feat["entered"] = 1
          open_trades[result.order] = feat["timestamp"]
          print(f"{now}:({magic_no}) ticket={result.order} prob={prob:.2%}", flush=True)
          msg = (f"({magic_no}) SL TP changed with\nSL:{round((new_sl),1)}\nTP:{round((new_tp),1)}\n"
                 f"{now}")                        
          send_telegram_message(msg)
      else:
          print(f"{now}: Order send failed, retcode={result.retcode}", flush=True)     

###############################################################################
# Block 5 : Main loop
###############################################################################
if not mt5.initialize(server=SERVER, login=LOGIN, password=PASSWORD):
    print(f"{datetime.now()}: MT5 initialize failed – {mt5.last_error()}", flush=True)
    sys.exit()
print(f"{datetime.now()}: Connected – {SYMBOL}", flush=True)
model = get_model()
df = load_dataset()
open_trades: Dict[int, int] = {}
time.sleep(1)
df = clean_dataset(df)
sync_existing_position()


# Suppress pandas FutureWarning for clean logs
warnings.filterwarnings("ignore", category=FutureWarning, module="pandas")

now = datetime.now()
current_hour = now.hour
first_trade = True

msg = (
    f"Bot opened at:\n"
    f"{now}")

print("Message to telegram:\n", msg)
send_telegram_message(msg)

while True:
    print(f"{datetime.now()}: Loop tick", flush=True)
    try:
        now = datetime.now()
        current_hour = now.hour        

        # === Only trade during betting hours ===
        if not (BETTING_START <= current_hour < BETTING_END):
            print(f"{now}: Outside betting hours ({BETTING_START}-{BETTING_END}), skipping trade logic.", flush=True)
            time.sleep(30)
            continue

        signal, filters, candle, trend_candle, atr_median = get_trade_signal()

        if candle is None:  # Data feed issue
            time.sleep(30) # Wait before retrying
            continue
        feat = build_features(candle, trend_candle, atr_median)
        feat["had_signal"] = int(signal is not None)

        df_new_row = pd.DataFrame([feat])
        # Only concatenate if df_new_row is not empty and not all-NA
        if not df_new_row.empty and df_new_row.notna().any().any():
            df = pd.concat([df, df_new_row], ignore_index=True)

        # ----- Model-based trade filtering -----
        prob = 0.5
        if model is not None:
            feature_cols = ["hour", "candle_size", "ema_distance", "atr", "adx", "rsi",
                            "volume", "trend_above_ema", "range_status", "volatility_level"]
            prob = model.predict_proba(df_new_row[feature_cols])[0, 1]
            print(f"Probability is {prob}", flush=True)
        total_trades_seen = (df["outcome"] != -1).sum()
        use_filter = (model is not None) and (total_trades_seen >= WARMUP_TRADES)
        accept_trade = (prob >= THRESHOLD) if use_filter else True

        if not first_trade:
            time_difference = (now - last_trade_opened).total_seconds()
            enough_time_passed = True if ((time_difference)>TIME_BETWEEN_TRADES) else False
        else:
            enough_time_passed = True
            time_difference = 0 
       
        print(f"Enough time passed signal is ({enough_time_passed}), {time_difference}s has passed, Accept trade is {accept_trade}, Probability is {prob}", flush=True)

        # ========== Only one trade open at a time (robust, using MT5) ==========
        if signal:
                if not has_open_position(SYMBOL, MAGIC_NO_1) and enough_time_passed and accept_trade:
                    tick = mt5.symbol_info_tick(SYMBOL)
                    price = tick.ask if signal == "BUY" else tick.bid
                    # IMPROVEMENT: Using ATR for a more dynamic Stop Loss
                    sl_points = candle.atr * SL_ATR_MULTI
                    tp_points = sl_points * RR_RATIO
                    order_type = mt5.ORDER_TYPE_BUY if signal == "BUY" else mt5.ORDER_TYPE_SELL 
                    sl_value = price - sl_points if signal == "BUY" else price + sl_points
                    tp_value = price + tp_points if signal == "BUY" else price - tp_points
                    magic_no = MAGIC_NO_1               
                    # ORDER SEND
                    send_order(order_type,price,sl_value,tp_value,magic_no,signal)
                    last_trade_opened = datetime.now()
                    first_trade = False
                elif not has_open_position(SYMBOL, MAGIC_NO_2) and enough_time_passed and accept_trade:
                    tick = mt5.symbol_info_tick(SYMBOL)
                    price = tick.ask if signal == "BUY" else tick.bid
                    # IMPROVEMENT: Using ATR for a more dynamic Stop Loss
                    sl_points = candle.atr * SL_ATR_MULTI
                    tp_points = sl_points * RR_RATIO
                    order_type = mt5.ORDER_TYPE_BUY if signal == "BUY" else mt5.ORDER_TYPE_SELL 
                    sl_value = price - sl_points if signal == "BUY" else price + sl_points
                    tp_value = price + tp_points if signal == "BUY" else price - tp_points
                    magic_no = MAGIC_NO_2               
                    # ORDER SEND
                    send_order(order_type,price,sl_value,tp_value,magic_no,signal)  
                    last_trade_opened = datetime.now()
                    first_trade = False
                elif not has_open_position(SYMBOL, MAGIC_NO_3) and enough_time_passed and accept_trade:
                    tick = mt5.symbol_info_tick(SYMBOL)
                    price = tick.ask if signal == "BUY" else tick.bid
                    # IMPROVEMENT: Using ATR for a more dynamic Stop Loss
                    sl_points = candle.atr * SL_ATR_MULTI
                    tp_points = sl_points * RR_RATIO
                    order_type = mt5.ORDER_TYPE_BUY if signal == "BUY" else mt5.ORDER_TYPE_SELL 
                    sl_value = price - sl_points if signal == "BUY" else price + sl_points
                    tp_value = price + tp_points if signal == "BUY" else price - tp_points
                    magic_no = MAGIC_NO_3               
                    # ORDER SEND
                    send_order(order_type,price,sl_value,tp_value,magic_no,signal) 
                    last_trade_opened = datetime.now()
                    first_trade = False
                elif not has_open_position(SYMBOL, MAGIC_NO_4) and enough_time_passed and accept_trade:
                    tick = mt5.symbol_info_tick(SYMBOL)
                    price = tick.ask if signal == "BUY" else tick.bid
                    # IMPROVEMENT: Using ATR for a more dynamic Stop Loss
                    sl_points = candle.atr * SL_ATR_MULTI
                    tp_points = sl_points * RR_RATIO
                    order_type = mt5.ORDER_TYPE_BUY if signal == "BUY" else mt5.ORDER_TYPE_SELL 
                    sl_value = price - sl_points if signal == "BUY" else price + sl_points
                    tp_value = price + tp_points if signal == "BUY" else price - tp_points
                    magic_no = MAGIC_NO_4               
                    # ORDER SEND
                    send_order(order_type,price,sl_value,tp_value,magic_no,signal)     
                    last_trade_opened = datetime.now()
                    first_trade = False
                elif not enough_time_passed or not accept_trade:
                    print(f"{now}:{signal} signal received, but not enough time elapsed, or not enough probability: {prob}", flush=True)
                    msg = (f"{now}:{signal} signal received, but not enough time elapsed, or not enough probability: {prob}")
                    send_telegram_message(msg)
                else:
                    print(f"{now}:{signal} signal received, but all positions open", flush=True)
                    msg = (f"{now}:{signal} signal received, but all positions open")                       
                    send_telegram_message(msg)
        else :
                positions_total=mt5.positions_total()
                if  positions_total>0:

                    positions = mt5.positions_get(symbol=SYMBOL)
                    ordernum = len(positions)
                    
                    for i in range(0, ordernum):
                        position = positions[i]
                        ticket = position.ticket
                        TP = position.tp
                        SL = position.sl
                        volume = position.volume
                        o_type = position.type
                        p_open = position.price_open
                        p_current = position.price_current
                        magic_no = position.magic

                        if ((magic_no == MAGIC_NO_1) or (magic_no == MAGIC_NO_2) or (magic_no == MAGIC_NO_3) or (magic_no == MAGIC_NO_4)):
                            #BUY ORDERS CHECK
                            if ((o_type == 0) and (SL < p_open) and (p_current > (p_open + SL_BE_DIFFERENCE))):
                                new_tp = TP + SLTP_ADJUST
                                new_sl = p_open
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)
                            elif ((o_type == 0) and (SL == p_open) and (p_current > (p_open + SL_ENTRY_DIFFERENCE))): 
                                new_tp = TP + SLTP_ADJUST
                                new_sl = SL + SLTP_ADJUST
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)
                            elif ((o_type == 0) and (SL > p_open) and (p_current > (SL + SL_TP_DIFFERENCE))): 
                                new_tp = TP + SLTP_ADJUST
                                new_sl = SL + SLTP_ADJUST
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)

                            #SELL ORDERS CHECK
                            elif ((o_type == 1) and (SL > p_open) and (p_current < (p_open - SL_BE_DIFFERENCE))): 
                                new_tp = TP - SLTP_ADJUST
                                new_sl = p_open
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)
                            elif ((o_type == 1) and (SL == p_open) and (p_current < (p_open - SL_ENTRY_DIFFERENCE))): 
                                new_tp = TP - SLTP_ADJUST
                                new_sl = SL - SLTP_ADJUST
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)
                            elif ((o_type == 1) and (SL < p_open) and (p_current < (SL - SL_TP_DIFFERENCE))): 
                                new_tp = TP - SLTP_ADJUST
                                new_sl = SL - SLTP_ADJUST
                                order_check_adjust(ticket,new_sl,new_tp,magic_no)
                            else:                        
                                print(f"{now}: Position {magic_no} open but nothing to adjust", flush=True) 
                        else:
                            print(f"{now}: No corresponding Magic numbers open", flush=True)
                        time.sleep(1)

                else:
                    print(f"{now}: Positions not open yet", flush=True)               

        # ----- Monitor and Record Closed Trades -----        
        # Get currently open positions to check what's closed
        current_positions = mt5.positions_get()
        current_position_ids = set()
        if current_positions:
            current_position_ids = {pos.identifier for pos in current_positions}
            print(f"Currently open positions: {current_position_ids}", flush=True)
        
        # Check each tracked position (not ticket!)
        for position_id in list(open_trades):
            
            # Check if position is still open
            if position_id in current_position_ids:
                print(f"Position {position_id} is still open, skipping", flush=True)
                continue
            
            # Position is closed, get the deals
            print(f"Position {position_id} has been closed", flush=True)
            
            # Get deal history (history_deals_get needs dates, not position parameter!)
            from_date = datetime.now() - timedelta(days=7)
            to_date = datetime.now() + timedelta(days=1)
            all_deals = mt5.history_deals_get(from_date, to_date)
            
            deals = []
            if all_deals:
                # Filter for this specific position_id
                deals = [d for d in all_deals if d.position_id == position_id]       
            
            if deals:
                # Calculate TOTAL profit (not just deals[0].profit!)
                profit = sum(d.profit + d.commission + d.swap for d in deals)
                
                signal_timestamp = open_trades.pop(position_id)
                
                # Update the original entry in the dataframe with the outcome
                if df['timestamp'].dtype != 'datetime64[ns]':
                    df['timestamp'] = pd.to_datetime(df['timestamp'], unit='s', errors='coerce')
                if isinstance(signal_timestamp, (int, float)):
                    signal_timestamp = pd.to_datetime(signal_timestamp, unit='s')
                
                # --- Update outcome with failsafe ---
                mask = df['timestamp'] == signal_timestamp
                
                # If no exact match, allow tolerance of ±2 second
                if not mask.any():
                    mask = (df['timestamp'] - signal_timestamp).abs() <= pd.Timedelta(seconds=2)
                
                if mask.any():
                    # Check if already updated to prevent duplicates
                    if (df.loc[mask, 'outcome'] != -1).any():
                        print(f"WARNING: Outcome already set for position {position_id}, skipping", flush=True)
                        continue
                    df.loc[mask, 'outcome'] = int(profit > 0)
                    print(f"{datetime.now()}: Position {position_id} closed. P/L: {profit:.2f}. Updating dataset.", flush=True)
                else:
                    print(f"WARNING: No matching row found for signal_timestamp {signal_timestamp}. ", flush=True)
                    print(f"Outcome for position {position_id} was NOT updated.", flush=True)
                    # ADD THIS ORPHANED TRADE ANYWAY:
                    new_row = {
                        'timestamp': signal_timestamp,
                        'outcome': int(profit > 0),
                        'hour': signal_timestamp.hour if hasattr(signal_timestamp, 'hour') else 12,
                        'candle_size': 0,
                        'ema_distance': 0,
                        'atr': 0,
                        'adx': 25,
                        'rsi': 50,
                        'volume': 0,
                        'trend_above_ema': 0,
                        'range_status': 0,
                        'volatility_level': 0,
                    }
                    df.loc[len(df)] = new_row
                    print(f"Added orphaned position {position_id} with outcome {new_row['outcome']}", flush=True)
                
                # ----- Retrain Model Periodically -----
                closed_trade_count = (df['outcome'] != -1).sum()
                if closed_trade_count > 0 and closed_trade_count % RETRAIN_EVERY == 0:
                    print(f"{datetime.now()}: Reached {closed_trade_count} closed trades. Retraining model...")
                    # Save OLD settings before learning
                    old_settings = current_settings_dict()
                    model = train_model(df)
                    if model:
                        print(f"{datetime.now()}: Model successfully retrained.", flush=True)
                        # Save NEW settings after learning
                        new_settings = current_settings_dict()
                        save_settings(old_settings, new_settings, closed_trade_count, model)
                        print(f"{datetime.now()}: Settings audit logged to {SETTING_FILE}", flush=True)
                else:
                    print(f"WARNING: No deals found for position {position_id}, removing from tracking", flush=True)
                    open_trades.pop(position_id, None)
        
        # Persist all updates to disk
        save_dataset(df)

    except Exception as e:
        print(f"{datetime.now()}: Runtime error – {e}", flush=True)
    time.sleep(max(0, LOOP_SECONDS - (time.time() % LOOP_SECONDS)))
