"""
Database Schema for MCPRepl Event Tracking

Persistent storage of all agent interactions, tool calls, and events.
"""
module Database

using SQLite
using Dates
using DBInterface
using JSON
using DataFrames

export init_db!,
    log_event!,
    get_events,
    get_session_stats,
    register_session!,
    get_active_sessions,
    close_db!

# Global database connection
const DB = Ref{Union{SQLite.DB,Nothing}}(nothing)

"""
Initialize the SQLite database with schema.
Creates tables if they don't exist.
"""
function init_db!(db_path::String = ".mcprepl/events.db")
    # Create .mcprepl directory if it doesn't exist
    mkpath(dirname(db_path))

    db = SQLite.DB(db_path)
    DB[] = db

    # Create sessions table
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        start_time DATETIME NOT NULL,
        last_activity DATETIME NOT NULL,
        status TEXT NOT NULL,
        metadata TEXT
    )
""",
    )

    # Create events table
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        event_type TEXT NOT NULL,
        timestamp DATETIME NOT NULL,
        duration_ms REAL,
        data TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
    )
""",
    )

    # Create indices for common queries
    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_session 
    ON events(session_id, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_type 
    ON events(event_type, timestamp DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_events_timestamp 
    ON events(timestamp DESC)
""",
    )

    return db
end

"""
Register or update a session in the database.
"""
function register_session!(
    session_id::String,
    status::String = "active";
    metadata::Dict = Dict(),
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    metadata_json = JSON.json(metadata)
    now_str = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

    # Insert or update session
    DBInterface.execute(
        db,
        """
        INSERT INTO sessions (session_id, start_time, last_activity, status, metadata)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            last_activity = excluded.last_activity,
            status = excluded.status,
            metadata = excluded.metadata
        """,
        (session_id, now_str, now_str, status, metadata_json),
    )
end

"""
Log an event to the database.
"""
function log_event!(
    session_id::String,
    event_type::String,
    data::Dict;
    duration_ms::Union{Float64,Nothing} = nothing,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
    data_json = JSON.json(data)

    DBInterface.execute(
        db,
        """
    INSERT INTO events (session_id, event_type, timestamp, duration_ms, data)
    VALUES (?, ?, ?, ?, ?)
""",
        (session_id, event_type, timestamp, duration_ms, data_json),
    )

    # Update session last_activity
    DBInterface.execute(
        db,
        """
    UPDATE sessions 
    SET last_activity = ?
    WHERE session_id = ?
""",
        (timestamp, session_id),
    )
end

"""
Retrieve recent events from the database.
"""
function get_events(;
    session_id::Union{String,Nothing} = nothing,
    event_type::Union{String,Nothing} = nothing,
    limit::Int = 100,
    offset::Int = 0,
)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    query = "SELECT * FROM events WHERE 1=1"
    params = []

    if session_id !== nothing
        query *= " AND session_id = ?"
        push!(params, session_id)
    end

    if event_type !== nothing
        query *= " AND event_type = ?"
        push!(params, event_type)
    end

    query *= " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
    push!(params, limit, offset)

    return DBInterface.execute(db, query, params) |> DataFrame
end

"""
Get statistics for a session.
"""
function get_session_stats(session_id::String)
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    # Get event counts by type
    event_counts =
        DBInterface.execute(
            db,
            """
        SELECT event_type, COUNT(*) as count
        FROM events
        WHERE session_id = ?
        GROUP BY event_type
    """,
            (session_id,),
        ) |> DataFrame

    # Get total execution time
    total_time = DBInterface.execute(
        db,
        """
    SELECT SUM(duration_ms) as total_ms
    FROM events
    WHERE session_id = ? AND duration_ms IS NOT NULL
""",
        (session_id,),
    )

    # Get session info
    session_info =
        DBInterface.execute(
            db,
            """
        SELECT * FROM sessions WHERE session_id = ?
    """,
            (session_id,),
        ) |> DataFrame

    return Dict(
        "session" => session_info,
        "event_counts" => event_counts,
        "total_execution_time_ms" => total_time,
    )
end

"""
Get all active sessions.
"""
function get_active_sessions()
    db = DB[]
    if db === nothing
        error("Database not initialized. Call init_db!() first.")
    end

    return DBInterface.execute(
        db,
        """
    SELECT * FROM sessions WHERE status = 'active'
    ORDER BY last_activity DESC
""",
    ) |> DataFrame
end

"""
Close the database connection.
"""
function close_db!()
    if DB[] !== nothing
        SQLite.close(DB[])
        DB[] = nothing
    end
end

end # module
