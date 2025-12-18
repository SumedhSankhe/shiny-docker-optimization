## Example Shiny Application for Docker Optimization Demo
## Interactive mtcars dataset explorer to demonstrate containerization

library(shiny)
library(ggplot2)
library(dplyr)
library(DT)

# Load mtcars dataset and add car names as a column
cars_data <- mtcars %>%
  mutate(car_name = rownames(mtcars)) %>%
  select(car_name, everything())

ui <- fluidPage(
  titlePanel("Motor Trend Cars Dashboard - Docker Demo"),

  sidebarLayout(
    sidebarPanel(
      selectInput("x_var",
                  "X-axis Variable:",
                  choices = c("Weight (1000 lbs)" = "wt",
                              "Horsepower" = "hp",
                              "Displacement" = "disp",
                              "1/4 Mile Time" = "qsec"),
                  selected = "wt"),

      selectInput("y_var",
                  "Y-axis Variable:",
                  choices = c("MPG" = "mpg",
                              "Horsepower" = "hp",
                              "Displacement" = "disp",
                              "1/4 Mile Time" = "qsec"),
                  selected = "mpg"),

      selectInput("color_var",
                  "Color By:",
                  choices = c("Cylinders" = "cyl",
                              "Transmission" = "am",
                              "Engine Type" = "vs",
                              "Gears" = "gear"),
                  selected = "cyl"),

      sliderInput("mpg_filter",
                  "Minimum MPG:",
                  min = 10,
                  max = 35,
                  value = 10,
                  step = 1),

      hr(),
      h4("Dataset Info"),
      p("The mtcars dataset comprises fuel consumption and 10 aspects of automobile design and performance for 32 automobiles (1973-74 models)."),
      p(strong("Total cars:"), nrow(cars_data))
    ),

    mainPanel(
      tabsetPanel(
        tabPanel("Scatter Plot",
                 h3("Relationship Explorer"),
                 plotOutput("scatter_plot", height = "500px"),
                 hr(),
                 h4("Summary Statistics"),
                 verbatimTextOutput("summary_stats")
        ),

        tabPanel("Distribution",
                 h3("MPG Distribution"),
                 plotOutput("mpg_dist", height = "400px"),
                 h3("Horsepower vs Cylinders"),
                 plotOutput("hp_by_cyl", height = "400px")
        ),

        tabPanel("Data Table",
                 h3("Full Dataset"),
                 DTOutput("cars_table")
        )
      )
    )
  )
)

server <- function(input, output, session) {

  # Reactive filtered data
  filtered_data <- reactive({
    cars_data %>%
      filter(mpg >= input$mpg_filter)
  })

  # Scatter plot
  output$scatter_plot <- renderPlot({
    data <- filtered_data()

    # Convert color variable to factor for better legend
    data[[input$color_var]] <- as.factor(data[[input$color_var]])

    ggplot(data, aes_string(x = input$x_var, y = input$y_var, color = input$color_var)) +
      geom_point(size = 4, alpha = 0.7) +
      geom_smooth(method = "lm", se = TRUE, alpha = 0.2) +
      scale_color_brewer(palette = "Set1") +
      labs(title = paste(input$y_var, "vs", input$x_var),
           x = names(which(c("wt" = "Weight (1000 lbs)",
                            "hp" = "Horsepower",
                            "disp" = "Displacement (cu.in.)",
                            "qsec" = "1/4 Mile Time (sec)") == input$x_var)),
           y = names(which(c("mpg" = "Miles Per Gallon",
                            "hp" = "Horsepower",
                            "disp" = "Displacement (cu.in.)",
                            "qsec" = "1/4 Mile Time (sec)") == input$y_var)),
           color = names(which(c("cyl" = "Cylinders",
                                "am" = "Transmission",
                                "vs" = "Engine",
                                "gear" = "Gears") == input$color_var))) +
      theme_minimal(base_size = 14) +
      theme(legend.position = "right")
  })

  # Summary statistics
  output$summary_stats <- renderPrint({
    data <- filtered_data()
    cat("Filtered Data Summary\n")
    cat("=====================\n\n")
    cat("Cars displayed:", nrow(data), "\n\n")
    cat("MPG Statistics:\n")
    cat("  Mean:", round(mean(data$mpg), 2), "\n")
    cat("  Median:", round(median(data$mpg), 2), "\n")
    cat("  Range:", round(min(data$mpg), 2), "-", round(max(data$mpg), 2), "\n\n")
    cat("Horsepower Statistics:\n")
    cat("  Mean:", round(mean(data$hp), 2), "\n")
    cat("  Median:", round(median(data$hp), 2), "\n")
    cat("  Range:", round(min(data$hp), 2), "-", round(max(data$hp), 2), "\n")
  })

  # MPG distribution
  output$mpg_dist <- renderPlot({
    data <- filtered_data()

    ggplot(data, aes(x = mpg)) +
      geom_histogram(bins = 15, fill = "#2563eb", alpha = 0.7, color = "white") +
      geom_vline(aes(xintercept = mean(mpg)),
                 color = "red", linetype = "dashed", size = 1) +
      labs(title = "Miles Per Gallon Distribution",
           subtitle = paste("Mean:", round(mean(data$mpg), 2), "MPG"),
           x = "Miles Per Gallon",
           y = "Count") +
      theme_minimal(base_size = 14)
  })

  # HP by cylinders
  output$hp_by_cyl <- renderPlot({
    data <- filtered_data()

    ggplot(data, aes(x = as.factor(cyl), y = hp, fill = as.factor(cyl))) +
      geom_boxplot(alpha = 0.7) +
      geom_jitter(width = 0.2, alpha = 0.5, size = 2) +
      scale_fill_brewer(palette = "Set2") +
      labs(title = "Horsepower by Number of Cylinders",
           x = "Number of Cylinders",
           y = "Horsepower",
           fill = "Cylinders") +
      theme_minimal(base_size = 14)
  })

  # Data table
  output$cars_table <- renderDT({
    data <- filtered_data() %>%
      mutate(
        am = ifelse(am == 0, "Automatic", "Manual"),
        vs = ifelse(vs == 0, "V-shaped", "Straight")
      ) %>%
      rename(
        Car = car_name,
        MPG = mpg,
        Cylinders = cyl,
        Displacement = disp,
        Horsepower = hp,
        `Rear Axle Ratio` = drat,
        `Weight (1000lbs)` = wt,
        `1/4 Mile Time` = qsec,
        Engine = vs,
        Transmission = am,
        Gears = gear,
        Carburetors = carb
      )

    datatable(data,
              options = list(
                pageLength = 15,
                scrollX = TRUE,
                dom = 'Bfrtip'
              ),
              rownames = FALSE,
              filter = 'top')
  })
}

shinyApp(ui = ui, server = server)
# Test comment 1766040179
