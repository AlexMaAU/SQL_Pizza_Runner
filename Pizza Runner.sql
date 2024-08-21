# There are some issues in the data format, fix them. And similar issues may occur when more new data added, please make sure we can format data in a simple way.
DELIMITER $$
DROP PROCEDURE IF EXISTS format_data;
CREATE PROCEDURE format_data()
BEGIN
	-- 更新日期格式
	UPDATE customer_orders
	SET order_time = STR_TO_DATE(order_time, '%d/%m/%Y %H:%i:%s');  # '%d/%m/%Y %H:%i:%s' 是用来描述 order_time 字符串的格式说明符，然后STR_TO_DATE会自动转换格式成 YYYY-MM-DD HH:MM:SS 标准格式
    
    -- 更新column type
    ALTER TABLE customer_orders
	MODIFY COLUMN order_time TIMESTAMP;
    
    ALTER TABLE runner_orders
	MODIFY COLUMN pickup_time TIMESTAMP;

	UPDATE runner_orders
	SET pickup_time = ''
	WHERE pickup_time IS NULL;

	UPDATE runner_orders
	SET distance = ''
	WHERE distance IS NULL;

	UPDATE runner_orders
	SET duration = ''
	WHERE duration IS NULL;

	UPDATE runner_orders
	SET cancellation = ''
	WHERE cancellation IS NULL;

	UPDATE runner_orders
	SET distance = TRIM(REPLACE(distance, 'km', ''))
	WHERE distance LIKE '%km';

	UPDATE runner_orders
	SET duration = TRIM(REPLACE(duration, 'minutes', ''))
	WHERE duration LIKE '%min%';

	UPDATE runner_orders
	SET duration = TRIM(REPLACE(duration, 'mins', ''))
	WHERE duration LIKE '%min%';

	UPDATE runner_orders
	SET duration = TRIM(REPLACE(duration, 'minute', ''))
	WHERE duration LIKE '%min%';
    
    ALTER TABLE runner_orders
	CHANGE COLUMN distance distance_km VARCHAR(7);
    
    ALTER TABLE runner_orders
    CHANGE COLUMN duration duration_minutes VARCHAR(10);
END $$
DELIMITER ;

CALL format_data();

## A. Pizza Metrics ##
# How many pizzas were ordered?
SELECT COUNT(*) AS pizza_order_count
FROM customer_orders;

# How many unique customer orders were made?
SELECT COUNT(DISTINCT(order_id)) AS total_unique_orders
FROM customer_orders;

# How many successful orders were delivered by each runner?
SELECT runner_id, COUNT(*) AS successful_orders
FROM runner_orders
WHERE cancellation = ''
GROUP BY runner_id;

# How many of each type of pizza was delivered?
WITH cte AS (
	SELECT pizza_id, COUNT(*) AS delivered_pizza_count
	FROM runner_orders AS ro
	LEFT JOIN customer_orders AS co
	ON ro.order_id = co.order_id
	WHERE cancellation = ''
	GROUP BY pizza_id
)
SELECT pizza_name, delivered_pizza_count
FROM cte
JOIN pizza_names AS pn
ON cte.pizza_id = pn.pizza_id;

# How many Vegetarian and Meatlovers were ordered by each customer?
SELECT customer_id, pizza_name, COUNT(pizza_name)
FROM customer_orders
NATURAL JOIN pizza_names
GROUP BY customer_id, pizza_name
ORDER BY customer_id;

# What was the maximum number of pizzas delivered in a single order?
SELECT order_id, COUNT(order_id) AS pizza_number
FROM customer_orders
NATURAL JOIN runner_orders
WHERE cancellation = ''
GROUP BY order_id
ORDER BY COUNT(order_id) DESC
LIMIT 1;

# What was the total volume of pizzas ordered for each hour of the day? I want to know what hours have highest and lowest order amount.
WITH cte AS (
	SELECT order_id, HOUR(order_time) AS order_hour
	FROM customer_orders
)
SELECT order_hour, COUNT(order_id) AS order_amount
FROM cte
GROUP BY order_hour
ORDER BY order_amount DESC, order_hour;

# What was the volume of orders for each day of the week? I want to know which day of the week has highest and lowest order amount. 
WITH cte AS (
	SELECT order_id, DAYNAME(order_time) AS order_day
	FROM customer_orders
)
SELECT order_day, COUNT(order_id) AS order_amount
FROM cte
GROUP BY order_day
ORDER BY order_amount DESC, order_day;

## B. Runner and Customer Experience ##
# How many runners signed up for each 1 week period? (i.e. week starts 2021-01-01)
WITH cte AS (
	SELECT runner_id, FLOOR(DATEDIFF(registration_date, '2021-01-01')/7+1) AS week_no  # DATEDIFF不包括起始日期本身
	FROM runners
)
SELECT week_no, COUNT(runner_id) AS signup_amount
FROM cte
GROUP BY week_no
ORDER BY signup_amount DESC;

# What was the average time in minutes it took for each runner to arrive at the Pizza Runner HQ to pickup the order?
SELECT ROUND(AVG(arrive_minutes), 2) AS avg_arrive_minutes
FROM (
	SELECT TIMESTAMPDIFF(MINUTE, order_time, pickup_time) AS arrive_minutes
	FROM customer_orders
	NATURAL JOIN runner_orders
	WHERE pickup_time != ''
) AS temp;

# Is there any relationship between the order number of pizzas and how long the order takes to prepare?
WITH cte AS (
	SELECT order_id, TIMESTAMPDIFF(MINUTE, order_time, pickup_time) AS prepare_minutes, COUNT(order_id) OVER (PARTITION BY order_id) AS order_amount
	FROM customer_orders
	NATURAL JOIN runner_orders
	WHERE cancellation = ''
)
SELECT order_amount, ROUND(AVG(prepare_minutes),2) AS avg_prepare_minutes
FROM cte
GROUP BY order_amount
ORDER BY order_amount DESC;

# What was the average distance travelled for each customer?
SELECT customer_id, ROUND(AVG(distance_km),2) AS avg_distance
FROM customer_orders
NATURAL JOIN runner_orders
WHERE cancellation = ''
GROUP BY customer_id;

# What was the difference between the longest and shortest delivery times for all orders?
WITH cte AS (
	SELECT MIN(duration_minutes) AS shortest_time, MAX(duration_minutes) AS longest_time
	FROM customer_orders
	NATURAL JOIN runner_orders
	WHERE cancellation = ''
)
SELECT (longest_time-shortest_time) AS delivery_time_difference
FROM cte;

# What was the average speed for each runner for each delivery and do you notice any trend for these values?
-- Runner 1 tends to have higher speed on short distance order
-- Runner 2 tends to have higher speed on long distance order
-- Runner 2 has 300% fluctuation rate, which should be investigated in because this may be dangerous
-- Both Runner 1 and Runner 2 have high fluctuation rate
SELECT runner_id, order_id, distance_km, ROUND(distance_km/(duration_minutes/60),2) AS speed_km_hour
FROM customer_orders
NATURAL JOIN runner_orders
WHERE cancellation = ''
ORDER BY runner_id;

# What is the successful delivery percentage for each runner?
WITH cte AS (
	SELECT runner_id, 
	SUM(
		CASE
			WHEN cancellation = '' THEN 1
			ELSE 0
		END
	) AS success_times,
	SUM(
		CASE
			WHEN cancellation != '' THEN 1
			ELSE 0
		END
	) AS cancel_times,
    COUNT(*) AS total_times
	FROM runner_orders
	GROUP BY runner_id
)
SELECT runner_id, ROUND((success_times/total_times),2)*100 AS success_percentage
FROM cte;

## C. Pricing and Ratings ##
# If a Meat Lovers pizza costs $12 and Vegetarian costs $10 and there were no charges for changes - how much money has Pizza Runner made so far if there are no delivery fees?
WITH cte AS (
	SELECT pizza_name, 
		CASE
			WHEN pizza_name='Meatlovers' THEN COUNT(pizza_name)*12
			WHEN pizza_name='Vegetarian' THEN COUNT(pizza_name)*10
	END AS income
	FROM customer_orders
	NATURAL JOIN pizza_names
    NATURAL JOIN runner_orders
    WHERE cancellation = ''
	GROUP BY pizza_name
)
SELECT SUM(income) AS total_income
FROM cte;

# If a Meat Lovers pizza was $12 and Vegetarian $10 fixed prices and each runner is paid $0.30 per kilometre traveled - how much money does Pizza Runner have left over after these deliveries?
SELECT ROUND(SUM(pizza_income-delivery_cost),2) AS total_profit
FROM (
	SELECT co.pizza_id, pn.pizza_name, ro.distance_km*0.3 AS delivery_cost, IF(pn.pizza_name='Meatlovers', 12, 10) AS pizza_income
	FROM customer_orders AS co
	JOIN pizza_names AS pn
	ON co.pizza_id = pn.pizza_id
	JOIN runner_orders AS ro
	ON co.order_id = ro.order_id
    WHERE cancellation = ''
) AS temp;

