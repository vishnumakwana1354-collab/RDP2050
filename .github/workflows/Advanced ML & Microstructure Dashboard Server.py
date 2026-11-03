import os
import sys
import subprocess
import json
import time
import threading
import numpy as np
from datetime import datetime

# Mandatory Auto-Installer for required Machine Learning and Web Framework libraries
REQUIRED_LIBRARIES = [
    "fastapi",
    "uvicorn",
    "pydantic",
    "tensorflow",
    "scikit-learn",
    "dash",
    "dash-bootstrap-components",
    "plotly",
    "pandas"
]

def auto_install_libraries():
    """Checks missing Python dependencies and automatically installs them."""
    for lib in REQUIRED_LIBRARIES:
        try:
            __import__(lib.replace("-", "_"))
        except ImportError:
            print(f"[AUTO-INSTALLER] Package '{lib}' missing. Installing now...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", lib])

auto_install_libraries()

from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
from typing import List, Optional, Dict, Any
import uvicorn

import pandas as pd
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, LSTM, Dropout
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import MinMaxScaler

import dash
from dash import dcc, html
from dash.dependencies import Input, Output
import dash_bootstrap_components as dbc
import plotly.graph_objs as go

# Global Thread-safe Memory Storage
MAX_MEMORY_SIZE = 1000
market_data_history = []
trade_decision_logs = []
memory_lock = threading.Lock()

# System Metrics
system_stats = {
    "total_requests": 0,
    "last_prediction": "N/A",
    "model_status": "Initializing ML...",
    "anomaly_count": 0,
    "confidence_trend": []
}

class MicrostructureMLEngine:
    """
    Advanced ML Engine using TensorFlow LSTM Deep Learning for price direction
    and Isolation Forest for Order Flow Anomaly / High-Frequency Sweep Detection.
    """
    def __init__(self):
        self.scaler = MinMaxScaler()
        self.anomaly_detector = IsolationForest(contamination=0.05, random_state=42)
        self.lstm_model = None
        self.is_trained = False
        self._build_mock_lstm()

    def _build_mock_lstm(self):
        """Constructs and pre-compiles a Deep LSTM Model for Sequence Prediction."""
        model = Sequential([
            LSTM(32, return_sequences=True, input_shape=(10, 4)),
            Dropout(0.2),
            LSTM(16),
            Dense(8, activation='relu'),
            Dense(1, activation='sigmoid') # Binary decision: Buy probability
        ])
        model.compile(optimizer='adam', loss='binary_crossentropy', metrics=['accuracy'])
        self.lstm_model = model
        
        # Warmup training with dummy microstructure data
        dummy_x = np.random.rand(50, 10, 4)
        dummy_y = np.random.choice([0, 1], size=(50, 1))
        self.lstm_model.fit(dummy_x, dummy_y, epochs=2, verbose=0)
        
        # Fit dummy anomaly detector
        dummy_features = np.random.rand(100, 4)
        self.anomaly_detector.fit(dummy_features)
        self.is_trained = True
        system_stats["model_status"] = "TensorFlow Engine Ready"

    def analyze_microstructure(self, facts: dict) -> dict:
        """
        Processes real-time tick features from MT5 EA using TensorFlow LSTM & Anomaly Detector.
        """
        snapback = float(facts.get("snapback_pips", 0.0))
        deviation_z = float(facts.get("deviation_z", 0.0))
        velocity = 1.0 if facts.get("high_velocity", False) else 0.0
        order_type_val = 1.0 if facts.get("order_type") == "BUY" else (-1.0 if facts.get("order_type") == "SELL" else 0.0)

        feature_vector = np.array([[snapback, deviation_z, velocity, order_type_val]])
        
        # 1. Anomaly Detection (Sweep / Liquidity Hunt Detection)
        anomaly_score = self.anomaly_detector.predict(feature_vector)[0]
        is_anomaly = (anomaly_score == -1)
        
        if is_anomaly:
            system_stats["anomaly_count"] += 1

        # 2. LSTM Sequence Inference (Simulated 10-step buffer)
        sequence_data = np.tile(feature_vector, (1, 10, 1))
        ml_buy_prob = float(self.lstm_model.predict(sequence_data, verbose=0)[0][0])
        
        # Decision Logic combining EA Rule Facts + TensorFlow ML Confidence
        base_type = facts.get("order_type", "WAIT")
        decision = "WAIT"
        confidence = 0.0
        reason = "ML Filters Evaluating Market..."

        if base_type == "SELL":
            if snapback >= 2.0 and deviation_z > 1.0 and (1.0 - ml_buy_prob) > 0.4:
                confidence = round(float(0.5 + (1.0 - ml_buy_prob) * 0.45), 2)
                decision = "SELL"
                reason = f"TF-LSTM Sell Signal ({int(confidence*100)}%) | Anomaly: {is_anomaly}"
        elif base_type == "BUY":
            if snapback >= 2.0 and deviation_z > 1.0 and ml_buy_prob > 0.4:
                confidence = round(float(0.5 + ml_buy_prob * 0.45), 2)
                decision = "BUY"
                reason = f"TF-LSTM Buy Signal ({int(confidence*100)}%) | Anomaly: {is_anomaly}"

        return {
            "decision": decision,
            "confidence": confidence,
            "reason": reason[:60],
            "ml_probability": round(ml_buy_prob, 4),
            "is_anomaly": is_anomaly
        }

ml_engine = MicrostructureMLEngine()

app = FastAPI(
    title="TensorFlow AI Hybrid Microstructure Bridge",
    description="High-frequency Trading AI Server for MT5 Expert Advisor with TensorFlow & Advanced Dashboard",
    version="3.0"
)

class AIRequest(BaseModel):
    payload: dict

@app.post("/analyze")
async def analyze_trade(request: AIRequest):
    system_stats["total_requests"] += 1
    user_content = "{}"
    messages = request.payload.get("messages", [])
    
    for msg in messages:
        if msg.get("role") == "user":
            user_content = msg.get("content", "{}")
            break

    try:
        facts = json.loads(user_content)
    except json.JSONDecodeError:
        return {"decision": "WAIT", "confidence": 0.0, "reason": "Invalid JSON Payload"}

    # Run ML Inference
    ml_result = ml_engine.analyze_microstructure(facts)
    
    # Store history for Dashboard
    timestamp = datetime.now().strftime("%H:%M:%S")
    record = {
        "timestamp": timestamp,
        "symbol": facts.get("symbol", "XAUUSD"),
        "order_type": facts.get("order_type", "WAIT"),
        "decision": ml_result["decision"],
        "confidence": ml_result["confidence"],
        "snapback": facts.get("snapback_pips", 0.0),
        "deviation_z": facts.get("deviation_z", 0.0),
        "reason": ml_result["reason"]
    }

    with memory_lock:
        trade_decision_logs.append(record)
        if len(trade_decision_logs) > MAX_MEMORY_SIZE:
            trade_decision_logs.pop(0)

    system_stats["last_prediction"] = f"{ml_result['decision']} ({ml_result['confidence']})"
    
    return {
        "decision": ml_result["decision"],
        "confidence": ml_result["confidence"],
        "reason": ml_result["reason"]
    }

dash_app = dash.Dash(
    __name__,
    requests_pathname_prefix="/dashboard/",
    external_stylesheets=[dbc.themes.DARKLY]
)

dash_app.layout = dbc.Container([
    dbc.Row([
        dbc.Col(html.H2("⚡ Hybrid Microstructure AI Intelligence Dashboard", className="text-center text-warning my-3"), width=12)
    ]),
    
    # KPI Metric Cards
    dbc.Row([
        dbc.Col(dbc.Card([
            dbc.CardBody([
                html.H5("Total EA Requests", className="card-title text-info"),
                html.H3(id="kpi-requests", className="text-white")
            ])
        ], color="dark", inverse=True), width=3),
        
        dbc.Col(dbc.Card([
            dbc.CardBody([
                html.H5("TensorFlow ML Model", className="card-title text-success"),
                html.H4(id="kpi-model-status", className="text-white")
            ])
        ], color="dark", inverse=True), width=3),

        dbc.Col(dbc.Card([
            dbc.CardBody([
                html.H5("Anomalies Sweeps Detected", className="card-title text-danger"),
                html.H3(id="kpi-anomalies", className="text-white")
            ])
        ], color="dark", inverse=True), width=3),

        dbc.Col(dbc.Card([
            dbc.CardBody([
                html.H5("Last Decision", className="card-title text-warning"),
                html.H4(id="kpi-last-decision", className="text-white")
            ])
        ], color="dark", inverse=True), width=3),
    ], className="mb-4"),

    # Live Charts Row
    dbc.Row([
        dbc.Col(dcc.Graph(id="chart-confidence-trend"), width=8),
        dbc.Col(dcc.Graph(id="chart-decision-pie"), width=4)
    ], className="mb-4"),

    # Recent Real-time Trade Signals Table
    dbc.Row([
        dbc.Col([
            html.H4("Real-Time Decision Logs (MT5 EA)", className="text-light mb-2"),
            html.Div(id="live-table-container")
        ], width=12)
    ]),

    # Refresh Interval Component (Updates every 2 seconds)
    dcc.Interval(id="interval-component", interval=2000, n_intervals=0)
], fluid=True)

@dash_app.callback(
    [
        Output("kpi-requests", "children"),
        Output("kpi-model-status", "children"),
        Output("kpi-anomalies", "children"),
        Output("kpi-last-decision", "children"),
        Output("chart-confidence-trend", "figure"),
        Output("chart-decision-pie", "figure"),
        Output("live-table-container", "children")
    ],
    [Input("interval-component", "n_intervals")]
)
def update_dashboard_live(n):
    with memory_lock:
        df = pd.DataFrame(trade_decision_logs)

    kpi_req = str(system_stats["total_requests"])
    kpi_status = system_stats["model_status"]
    kpi_anom = str(system_stats["anomaly_count"])
    kpi_last = system_stats["last_prediction"]

    # Default empty charts if no data yet
    if df.empty:
        empty_fig = go.Figure().update_layout(template="plotly_dark", title="Awaiting MetaTrader 5 EA Data...")
        return kpi_req, kpi_status, kpi_anom, kpi_last, empty_fig, empty_fig, html.P("No signals logged yet.", className="text-muted")

    # 1. Line Chart - Confidence Trend
    fig_trend = go.Figure()
    fig_trend.add_trace(go.Scatter(
        x=df["timestamp"], y=df["confidence"],
        mode="lines+markers",
        name="AI Confidence",
        line=dict(color="#00bc8c", width=3)
    ))
    fig_trend.update_layout(
        title="Real-Time TensorFlow AI Confidence Trend",
        template="plotly_dark",
        xaxis_title="Time",
        yaxis_title="Confidence Level (0.0 - 1.0)",
        yaxis=dict(range=[0, 1])
    )

    # 2. Pie Chart - Decisions Breakdown
    decision_counts = df["decision"].value_counts()
    fig_pie = go.Figure(data=[go.Pie(
        labels=decision_counts.index,
        values=decision_counts.values,
        hole=.4,
        marker_colors=["#375a7f", "#00bc8c", "#e74c3c"]
    )])
    fig_pie.update_layout(title="Decision Distribution", template="plotly_dark")

    # 3. Live Logs Table
    table_header = [html.Thead(html.Tr([
        html.Th("Timestamp"), html.Th("Symbol"), html.Th("EA Signal"), 
        html.Th("AI Decision"), html.Th("Confidence"), html.Th("Snapback"), html.Th("Reason")
    ]))]
    
    rows = []
    for _, row in df.tail(10).iloc[::-1].iterrows():
        badge_color = "success" if row["decision"] == "BUY" else ("danger" if row["decision"] == "SELL" else "secondary")
        rows.append(html.Tr([
            html.Td(row["timestamp"]),
            html.Td(row["symbol"]),
            html.Td(row["order_type"]),
            html.Td(dbc.Badge(row["decision"], color=badge_color, className="px-2 py-1")),
            html.Td(f"{int(row['confidence']*100)}%"),
            html.Td(f"{row['snapback']} pips"),
            html.Td(row["reason"])
        ]))
    
    table_body = [html.Tbody(rows)]
    live_table = dbc.Table(table_header + table_body, bordered=True, dark=True, hover=True, responsive=True)

    return kpi_req, kpi_status, kpi_anom, kpi_last, fig_trend, fig_pie, live_table

from fastapi.middleware.wsgi import WSGIMiddleware
app.mount("/dashboard", WSGIMiddleware(dash_app.server))

if __name__ == "__main__":
    print("\n=======================================================")
    print(" 🚀 Hybrid Microstructure AI & TensorFlow ML Bridge")
    print("=======================================================")
    print(" 📍 MetaTrader 5 Endpoint:  http://127.0.0.1:8787/analyze")
    print(" 📊 Advanced ML Dashboard: http://127.0.0.1:8787/dashboard/")
    print("=======================================================\n")
    
    uvicorn.run(app, host="127.0.0.1", port=8787)