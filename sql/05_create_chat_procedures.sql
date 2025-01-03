-- 切换到e2ee_chat数据库
\c e2ee_chat

-- 获取用户最近会话列表函数
CREATE OR REPLACE FUNCTION get_recent_sessions(
    p_user_id UUID
) RETURNS TABLE(
    session_id UUID,
    initiator_id UUID,
    participant_id UUID,
    created_at TIMESTAMPTZ,
    message_counter BIGINT,
    last_message_id UUID,
    last_message_at TIMESTAMPTZ
)
SECURITY DEFINER
AS $$
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 返回会话列表
    RETURN QUERY
    SELECT s.session_id,
           s.initiator_id,
           s.participant_id,
           s.created_at,
           s.message_counter,
           s.last_message_id,
           s.last_message_at
    FROM chat_sessions s
    WHERE s.initiator_id = p_user_id 
       OR s.participant_id = p_user_id
    ORDER BY s.last_message_at DESC NULLS LAST;
END;
$$ LANGUAGE plpgsql;

-- 获取会话未读消息数函数
CREATE OR REPLACE FUNCTION get_unread_count(
    p_session_id UUID,
    p_user_id UUID
) RETURNS INTEGER
SECURITY DEFINER
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)::INTEGER INTO v_count
    FROM chat_messages m
    WHERE m.session_id = p_session_id
      AND m.receiver_id = p_user_id
      AND m.is_read = FALSE;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- 获取会话首条未读消息ID函数
CREATE OR REPLACE FUNCTION get_first_unread(
    p_user_id UUID,
    p_session_id UUID
) RETURNS UUID
SECURITY DEFINER
AS $$
DECLARE
    v_message_id UUID;
BEGIN
    -- 尝试获取第一条未读消息
    SELECT m.message_id INTO v_message_id
    FROM chat_messages m
    WHERE m.session_id = p_session_id
      AND m.receiver_id = p_user_id
      AND m.is_read = FALSE
    ORDER BY m.cursor
    LIMIT 1;
    
    -- 如果没有未读消息，返回最后一条消息ID
    IF v_message_id IS NULL THEN
        SELECT m.message_id INTO v_message_id
        FROM chat_messages m
        WHERE m.session_id = p_session_id
        ORDER BY m.cursor DESC
        LIMIT 1;
    END IF;
    
    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql;

-- 获取指定游标之前的消息函数
CREATE OR REPLACE FUNCTION get_messages_before(
    p_user_id UUID,
    p_session_id UUID,
    p_cursor BIGINT DEFAULT -1,
    p_limit INTEGER DEFAULT 50
) RETURNS TABLE(
    message_id UUID,
    cursor BIGINT,
    sender_id UUID,
    receiver_id UUID,
    is_system BOOLEAN,
    is_read BOOLEAN,
    message_iv BYTEA,
    message_content BYTEA,
    sent_at TIMESTAMPTZ
)
SECURITY DEFINER
AS $$
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 标记要返回的接收消息为已读
    UPDATE chat_messages AS cm
    SET is_read = TRUE
    WHERE cm.session_id = p_session_id
      AND cm.receiver_id = p_user_id
      AND cm.is_read = FALSE
      AND (p_cursor = -1 OR cm.cursor <= p_cursor)
      AND cm.cursor >= (
          SELECT COALESCE(MIN(sub.cursor), 0)
          FROM (
              SELECT sub_cm.cursor
              FROM chat_messages AS sub_cm
              WHERE sub_cm.session_id = p_session_id
                AND (p_cursor = -1 OR sub_cm.cursor <= p_cursor)
              ORDER BY sub_cm.cursor DESC
              LIMIT p_limit
          ) AS sub
      );
    
    -- 返回消息列表
    RETURN QUERY
    SELECT m.message_id,
           m.cursor,
           m.sender_id,
           m.receiver_id,
           m.is_system,
           m.is_read,
           m.message_iv,
           m.message_content,
           m.sent_at
    FROM chat_messages m
    WHERE m.session_id = p_session_id
      AND (p_cursor = -1 OR m.cursor <= p_cursor)
    ORDER BY m.cursor DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- 获取指定游标之后的消息函数
CREATE OR REPLACE FUNCTION get_messages_after(
    p_user_id UUID,
    p_session_id UUID,
    p_cursor BIGINT DEFAULT -1,
    p_limit INTEGER DEFAULT 50
) RETURNS TABLE(
    message_id UUID,
    cursor BIGINT,
    sender_id UUID,
    receiver_id UUID,
    is_system BOOLEAN,
    is_read BOOLEAN,
    message_iv BYTEA,
    message_content BYTEA,
    sent_at TIMESTAMPTZ
)
SECURITY DEFINER
AS $$
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 标记要返回的接收消息为已读
    UPDATE chat_messages AS cm
    SET is_read = TRUE
    WHERE cm.session_id = p_session_id
      AND cm.receiver_id = p_user_id
      AND cm.is_read = FALSE
      AND (p_cursor = -1 OR cm.cursor >= p_cursor)
      AND cm.cursor <= (
          SELECT COALESCE(MAX(sub.cursor), 0)
          FROM (
              SELECT sub_cm.cursor
              FROM chat_messages AS sub_cm
              WHERE sub_cm.session_id = p_session_id
                AND (p_cursor = -1 OR sub_cm.cursor >= p_cursor)
              ORDER BY sub_cm.cursor
              LIMIT p_limit
          ) AS sub
      );
    
    -- 返回消息列表
    RETURN QUERY
    SELECT m.message_id,
           m.cursor,
           m.sender_id,
           m.receiver_id,
           m.is_system,
           m.is_read,
           m.message_iv,
           m.message_content,
           m.sent_at
    FROM chat_messages m
    WHERE m.session_id = p_session_id
      AND (p_cursor = -1 OR m.cursor >= p_cursor)
    ORDER BY m.cursor
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- 发送消息函数
CREATE OR REPLACE FUNCTION send_message(
    p_user_id UUID,
    p_session_id UUID,
    p_message_iv BYTEA,
    p_message_content BYTEA,
    p_is_system BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
SECURITY DEFINER
AS $$
DECLARE
    v_session RECORD;
    v_new_cursor BIGINT;
    v_message_id UUID;
BEGIN
    -- 获取并锁定会话信息
    SELECT * INTO v_session
    FROM chat_sessions
    WHERE session_id = p_session_id
    FOR UPDATE;
    
    -- 验证会话存在且用户有权限
    IF v_session.session_id IS NULL OR 
       (v_session.initiator_id != p_user_id AND v_session.participant_id != p_user_id) THEN
        RETURN FALSE;
    END IF;
    
    -- 递增消息计数器
    UPDATE chat_sessions
    SET message_counter = message_counter + 1
    WHERE session_id = p_session_id
    RETURNING message_counter INTO v_new_cursor;
    
    -- 插入新消息
    INSERT INTO chat_messages (
        message_id,
        session_id,
        cursor,
        sender_id,
        receiver_id,
        message_iv,
        message_content,
        is_system,
        sent_at
    ) VALUES (
        gen_random_uuid(),
        p_session_id,
        v_new_cursor,
        p_user_id,
        CASE 
            WHEN v_session.initiator_id = p_user_id THEN v_session.participant_id
            ELSE v_session.initiator_id
        END,
        p_message_iv,
        p_message_content,
        p_is_system,
        CURRENT_TIMESTAMP
    )
    RETURNING message_id INTO v_message_id;
    
    -- 更新会话最后消息信息
    UPDATE chat_sessions
    SET last_message_id = v_message_id,
        last_message_at = CURRENT_TIMESTAMP
    WHERE session_id = p_session_id;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- 获取或创建会话函数
CREATE OR REPLACE FUNCTION get_or_create_session(
    p_user_id UUID,
    p_other_user_id UUID
) RETURNS UUID
SECURITY DEFINER
AS $$
DECLARE
    v_session_id UUID;
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 检查用户是否存在
    IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE user_id = p_other_user_id) THEN
        RETURN NULL;
    END IF;
    
    -- 检查是否已存在会话（不区分发起者和参与者）
    SELECT session_id INTO v_session_id
    FROM chat_sessions
    WHERE (initiator_id = LEAST(p_user_id, p_other_user_id) 
       AND participant_id = GREATEST(p_user_id, p_other_user_id));
    
    -- 如果会话不存在则创建新会话
    IF v_session_id IS NULL THEN
        INSERT INTO chat_sessions (
            initiator_id,
            participant_id
        ) VALUES (
            LEAST(p_user_id, p_other_user_id),
            GREATEST(p_user_id, p_other_user_id)
        )
        RETURNING session_id INTO v_session_id;
    END IF;
    
    RETURN v_session_id;
END;
$$ LANGUAGE plpgsql;

-- 获取指定会话函数
CREATE OR REPLACE FUNCTION get_session(
    p_user_id UUID,
    p_session_id UUID
) RETURNS TABLE(
    session_id UUID,
    initiator_id UUID,
    participant_id UUID,
    created_at TIMESTAMPTZ,
    message_counter BIGINT,
    last_message_id UUID,
    last_message_at TIMESTAMPTZ
)
SECURITY DEFINER
AS $$
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 返回会话信息（仅当用户是会话的发起者或参与者时）
    RETURN QUERY
    SELECT s.session_id,
           s.initiator_id,
           s.participant_id,
           s.created_at,
           s.message_counter,
           s.last_message_id,
           s.last_message_at
    FROM chat_sessions s
    WHERE s.session_id = p_session_id
      AND (s.initiator_id = p_user_id OR s.participant_id = p_user_id);
END;
$$ LANGUAGE plpgsql;

-- 获取指定消息函数
CREATE OR REPLACE FUNCTION get_message(
    p_user_id UUID,
    p_message_id UUID
) RETURNS TABLE(
    message_id UUID,
    session_id UUID,
    cursor BIGINT,
    sender_id UUID,
    receiver_id UUID,
    is_system BOOLEAN,
    is_read BOOLEAN,
    message_iv BYTEA,
    message_content BYTEA,
    sent_at TIMESTAMPTZ
)
SECURITY DEFINER
AS $$
BEGIN
    -- 更新最后在线时间
    PERFORM update_last_online(p_user_id);
    
    -- 返回消息信息（仅当用户是消息的发送者或接收者时）
    RETURN QUERY
    SELECT m.message_id,
           m.session_id,
           m.cursor,
           m.sender_id,
           m.receiver_id,
           m.is_system,
           m.is_read,
           m.message_iv,
           m.message_content,
           m.sent_at
    FROM chat_messages m
    JOIN chat_sessions s ON m.session_id = s.session_id
    WHERE m.message_id = p_message_id
      AND (s.initiator_id = p_user_id OR s.participant_id = p_user_id)
    LIMIT 1;
    
    -- 如果用户是接收者且消息未读，标记为已读
    UPDATE chat_messages
    SET is_read = TRUE
    WHERE message_id = p_message_id
      AND receiver_id = p_user_id
      AND is_read = FALSE;
END;
$$ LANGUAGE plpgsql;

-- 添加函数注释
COMMENT ON FUNCTION get_recent_sessions IS '获取用户最近会话列表，按最后消息时间降序排序';
COMMENT ON FUNCTION get_unread_count IS '获取会话中用户的未读消息数量';
COMMENT ON FUNCTION get_first_unread IS '获取会话中用户的首条未读消息ID，若全部已读则返回最后消息ID';
COMMENT ON FUNCTION get_messages_before IS '获取指定游标之前的消息，自动标记接收消息为已读';
COMMENT ON FUNCTION get_messages_after IS '获取指定游标之后的消息，自动标记接收消息为已读';
COMMENT ON FUNCTION send_message IS '发送新消息，自动更新会话信息';
COMMENT ON FUNCTION get_or_create_session IS '获取或创建会话，若会话不存在则创建新会话';
COMMENT ON FUNCTION get_session IS '获取指定会话，仅返回用户有权访问的会话';
COMMENT ON FUNCTION get_message IS '获取指定消息，自动标记接收消息为已读';
