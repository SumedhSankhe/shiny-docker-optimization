## Example Shiny Application for Docker Optimization Demo
## Simple proteomics QC dashboard to demonstrate containerization

library(shiny)
library(ggplot2)
library(dplyr)
library(DT)

# Simulate proteomics QC data
generate_qc_data <- function(n_samples = 50) {
  data.frame(
    sample_id = paste0("S", 1:n_samples),
    protein_count = rnorm(n_samples, mean = 5000, sd = 500),
    cv = rnorm(n_samples, mean = 15, sd = 3),
    missing_values = rbinom(n_samples, size = 100, prob = 0.05),
    stringsAsFactors = FALSE
  )
}

ui <- fluidPage(
  titlePanel("Proteomics QC Dashboard - Docker Demo"),
  
  sidebarLayout(
    sidebarPanel(
      sliderInput("n_samples", 
                  "Number of Samples:", 
                  min = 10, 
                  max = 100, 
                  value = 50),
      
      numericInput("cv_threshold",
                   "CV Threshold (%):",
                   value = 20,
                   min = 5,
                   max = 50),
      
      actionButton("refresh", "Refresh Data", class = "btn-primary")
    ),
    
    mainPanel(
      tabsetPanel(
        tabPanel("Summary",
                 h3("Quality Control Metrics"),
                 plotOutput("protein_dist"),
                 plotOutput("cv_plot")
        ),
        
        tabPanel("Data Table",
                 DTOutput("qc_table")
        )
      )
    )
  )
)

server <- function(input, output, session) {
  
  # Reactive data generation
  qc_data <- eventReactive(input$refresh, {
    generate_qc_data(input$n_samples)
  }, ignoreNULL = FALSE)
  
  # Protein count distribution
  output$protein_dist <- renderPlot({
    data <- qc_data()
    
    ggplot(data, aes(x = protein_count)) +
      geom_histogram(bins = 30, fill = "#2563eb", alpha = 0.7) +
      labs(title = "Protein Count Distribution",
           x = "Proteins Identified",
           y = "Frequency") +
      theme_minimal()
  })
  
  # CV plot with threshold
  output$cv_plot <- renderPlot({
    data <- qc_data()
    
    ggplot(data, aes(x = sample_id, y = cv)) +
      geom_point(aes(color = cv > input$cv_threshold), size = 3) +
      geom_hline(yintercept = input$cv_threshold, 
                 linetype = "dashed", 
                 color = "red") +
      scale_color_manual(values = c("TRUE" = "red", "FALSE" = "#2563eb"),
                        labels = c("Pass", "Fail"),
                        name = "QC Status") +
      labs(title = "Coefficient of Variation by Sample",
           x = "Sample ID",
           y = "CV (%)") +
      theme_minimal() +
      theme(axis.text.x = element_blank())
  })
  
  # Data table
  output$qc_table <- renderDT({
    data <- qc_data() %>%
      mutate(qc_status = ifelse(cv > input$cv_threshold, "Fail", "Pass"))
    
    datatable(data, 
              options = list(pageLength = 10),
              rownames = FALSE)
  })
}

shinyApp(ui = ui, server = server)
